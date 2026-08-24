# Manual TLS certificate rotation (cert-manager break-glass fallback)

> **What this is:** the last-resort procedure for the *double failure* where
> cert-manager itself is broken **and** a wildcard TLS cert has already expired, so
> every `https://*.k8s.rommelporras.com` site throws a browser cert error. You
> hand-mint a temporary bridge cert to get HTTPS back, then repair cert-manager and
> let it re-issue the real Let's Encrypt cert.
>
> **Try the normal path FIRST.** This document is only for when that path fails:
> - [../runbooks/00-EMERGENCY.md §4.1 TLS certificate problems](../runbooks/00-EMERGENCY.md#41-tls-certificate-problems)
> - [../runbooks/certificates.md](../runbooks/certificates.md)
>
> Related: [../runbooks/vault.md](../runbooks/vault.md) (the Cloudflare token lives
> in Vault), [managing-secrets.md](managing-secrets.md) (how secrets are managed),
> [../context/Gateway.md](../context/Gateway.md) (Gateway / HTTPRoute / TLS layout).

---

## 0. Do NOT be here yet - qualify the failure first

Use this fallback **only** if BOTH are true:

1. A wildcard cert Secret is **actually expired or invalid** (every web app shows a
   cert error, not just one device), AND
2. cert-manager **cannot fix it itself** - it's crash-looping, its CRDs are gone,
   its webhook is down so no `Certificate`/`CertificateRequest` can even be
   created, or the ACME/Cloudflare path is dead with no quick fix.

If cert-manager is healthy and only the *cert* is stale, the correct fix is one
line (delete the backing Secret so cert-manager re-issues) - do that instead:

```bash
# NORMAL fix, NOT this doc: force a reissue when cert-manager still works.
# (cmctl / kubectl cert-manager plugin is NOT installed, so this delete is the path.)
kubectl-admin delete secret wildcard-k8s-tls -n default
```

See [00-EMERGENCY.md §4.1](../runbooks/00-EMERGENCY.md#41-tls-certificate-problems)
for the full normal triage (Cloudflare token expiry is the usual root cause).

> Note: cert-manager objects (`certificate`, `clusterissuer`, `order`, `challenge`)
> and secret `get`/`list` are **RBAC-blocked on `kubectl-homelab`** (verified:
> `Forbidden ... cannot list resource "certificates"`). Every read and write below
> uses `kubectl-admin` for that reason.

---

## 1. The facts you need (verified against the live cluster)

- **cert-manager version:** `v1.19.2` (controller, cainjector, webhook), installed
  as an ArgoCD **Helm** app named `cert-manager`
  (`manifests/argocd/apps/cert-manager.yaml`, OCI chart
  `quay.io/jetstack/charts/cert-manager`, CRDs bundled in the chart). Its custom
  manifests (the ClusterIssuers + Cloudflare ExternalSecret) are a separate ArgoCD
  app `cert-manager-manifests`
  (`manifests/argocd/apps/cert-manager-manifests.yaml`, path `manifests/cert-manager`,
  prune + selfHeal on).
- **Deployment names** (needed for `logs`/`scale`): `cert-manager`,
  `cert-manager-cainjector`, `cert-manager-webhook`, all in ns `cert-manager`.
- **Three wildcard cert Secrets**, all type `kubernetes.io/tls`, all in the
  **`default`** namespace:

  | Secret name | Covers | Gateway listener |
  |-------------|--------|------------------|
  | `wildcard-k8s-tls` | `*.k8s.rommelporras.com` | `https` |
  | `wildcard-dev-k8s-tls` | `*.dev.k8s.rommelporras.com` | `https-dev` |
  | `wildcard-stg-k8s-tls` | `*.stg.k8s.rommelporras.com` | `https-stg` |

- **How they exist:** there is **NO explicit `kind: Certificate` in Git.** The
  Gateway `homelab-gateway` (kind `Gateway`, ns `default`,
  `manifests/gateway/homelab-gateway.yaml`) carries the annotation
  `cert-manager.io/cluster-issuer: letsencrypt-prod`. cert-manager's Gateway shim
  reads that annotation plus each listener's `tls.certificateRefs[].name` and
  **auto-creates** a matching `Certificate` object (owned by the Gateway) that in
  turn produces the Secret. Confirmed live: `Certificate/wildcard-k8s-tls` has
  `ownerReferences: [{kind: Gateway, name: homelab-gateway, controller: true}]`,
  `issuerRef` ClusterIssuer `letsencrypt-prod`, `dnsNames: ["*.k8s.rommelporras.com"]`
  (wildcard only - **the real cert does NOT cover the bare apex** `k8s.rommelporras.com`).
- **Only ACME ClusterIssuers exist** cluster-wide: `letsencrypt-prod` and
  `letsencrypt-staging`, both DNS-01 via Cloudflare (`cloudflare-api-token`
  Secret, key `api-token`, `manifests/cert-manager/cluster-issuer.yaml`). **There
  is NO SelfSigned or CA ClusterIssuer** - you cannot mint an offline cert without
  adding one (Option A) or bypassing cert-manager entirely (Option B). (An
  unrelated **namespaced** SelfSigned `Issuer` `inteldeviceplugins-selfsigned-issuer`
  exists in `intel-device-plugins`; it is scoped to that namespace and is not usable
  for the `default`-namespace wildcard certs.)
- **Rate limits:** the real reissue at the end goes to **Let's Encrypt
  production**, which enforces rate limits (notably ~5 duplicate certs / 168h per
  exact name set). Do **not** loop deletes/reissues while debugging - you can lock
  yourself out of new certs for a week. Use `letsencrypt-staging` for any dry runs.

---

## 2. Choose your option

- **Option A (preferred, GitOps-consistent):** cert-manager is *partially* alive -
  the controller and webhook are up enough to reconcile a `Certificate`, but the
  ACME/Cloudflare path is broken (expired token, Cloudflare down, ACME rate-limited).
  You add a **temporary SelfSigned ClusterIssuer + explicit Certificate** so
  cert-manager mints a self-signed bridge cert into the same Secret name. Browsers
  will warn (untrusted), but TLS terminates and apps load. Go to [§3](#3-option-a).

- **Option B (raw, cert-manager fully down):** the webhook is down / CRDs gone /
  controller won't run at all, so cert-manager can't create anything. You generate a
  self-signed cert with `openssl` and write the Secret directly with `kubectl-admin`.
  Go to [§4](#4-option-b).

Quick test to decide:

```bash
# Are the cert-manager pods actually running?
kubectl-admin get pods -n cert-manager

# Can the API server even accept a Certificate? (webhook alive?)
kubectl-admin get validatingwebhookconfigurations | grep cert-manager   # cert-manager-webhook
kubectl-admin get crd | grep cert-manager.io   # certificates.cert-manager.io present?
```

If the pods are up and the CRDs/webhook exist -> Option A. If any of those are
missing or the webhook rejects everything -> Option B.

---

## 3. Option A

> **This creates/mutates cluster state.** It adds a SelfSigned ClusterIssuer and an
> explicit Certificate. Both are temporary and get removed in [§5](#5-restore-cert-manager-and-re-issue-the-real-cert).

### 3.1 Prefer to do it through Git if ArgoCD is working

If ArgoCD can still sync, the clean way is to commit the two temporary resources to
`manifests/cert-manager/` and let the `cert-manager-manifests` app apply them
(that app path is `manifests/cert-manager`, prune + selfHeal on). But during an
outage that round-trip is often too slow, and committing throwaway break-glass YAML
is noise. Applying directly with `kubectl-admin` is acceptable here **because these
two objects are temporary and you will delete them in §5** - just remember they are
NOT in Git, so they won't self-heal if pruned, and you must remove them by hand.

### 3.2 Add a temporary SelfSigned ClusterIssuer

```bash
# MUTATES CLUSTER STATE - creates a ClusterIssuer.
cat <<'EOF' | kubectl-admin apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-breakglass
spec:
  selfSigned: {}
EOF

kubectl-admin get clusterissuer selfsigned-breakglass -o wide   # READY should be True
```

### 3.3 Create an explicit bridge Certificate for the expired Secret

Do this for whichever wildcard is expired. Example is the base tier
(`wildcard-k8s-tls`). Repeat with the dev/stg names + dnsNames if those are also
expired.

> **WARNING - name collision with the Gateway-managed Certificate.** The Gateway
> shim auto-creates a `Certificate` named `wildcard-k8s-tls` (owned by the Gateway,
> `controller: true`) targeting `secretName: wildcard-k8s-tls`. If you create your
> own Certificate with the **same name**, `apply` will refuse (immutable
> `secretName`/owner conflict) or fight the shim. Use a **distinct Certificate name**
> (`wildcard-k8s-breakglass` below) but point it at the **same `secretName`** so the
> Gateway keeps consuming it. Only one Certificate should "own" the Secret at a time;
> two controllers writing the same Secret thrash. If cert-manager is partially up and
> the shim is actively re-creating its own Certificate, temporarily remove the
> annotation from the Gateway first (see the note after the block).

```bash
# MUTATES CLUSTER STATE - creates a Certificate that mints a self-signed cert
# into the EXISTING Secret name the Gateway references.
cat <<'EOF' | kubectl-admin apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: wildcard-k8s-breakglass
  namespace: default
spec:
  secretName: wildcard-k8s-tls          # MUST match the Gateway certificateRef
  dnsNames:
    - "*.k8s.rommelporras.com"          # the real cert covers ONLY this wildcard
    - "k8s.rommelporras.com"            # apex added defensively; harmless if unused
  duration: 168h                        # 7 days - short, this is a bridge only
  issuerRef:
    name: selfsigned-breakglass
    kind: ClusterIssuer
    group: cert-manager.io
EOF

# Watch it become Ready and repopulate the Secret:
kubectl-admin get certificate -n default wildcard-k8s-breakglass -o wide
```

> If the Gateway shim keeps re-asserting its own `wildcard-k8s-tls` Certificate and
> overwriting yours, pause the shim by removing the issuer annotation from the
> Gateway for the duration of the outage:
> ```bash
> # MUTATES the Gateway. REMEMBER to restore this in §5.
> kubectl-admin annotate gateway homelab-gateway -n default cert-manager.io/cluster-issuer-
> ```
> Restoring cert-manager (§5) puts the annotation back and lets the shim reclaim
> the Secret. Note: the Gateway is ArgoCD-managed (`gateway` app, path
> `manifests/gateway`, selfHeal on), so ArgoCD may re-add the annotation on its next
> sync - that is fine and expected once cert-manager is healthy; during the outage,
> if ArgoCD keeps re-adding it faster than you want, you can pause auto-sync (see
> [§4.4](#44-stop-argocd-from-fighting-you)).

### 3.4 Make the Gateway serve the new cert

Cilium's Gateway/envoy usually reloads on Secret change automatically. If browsers
still see the old/expired cert after ~1 min, nudge the data plane:

```bash
# Restart the Cilium operator (re-reconciles Gateway/HTTPRoute wiring):
kubectl-admin rollout restart deployment/cilium-operator -n kube-system
```

Verify (see [§6](#6-verify)), then proceed to [§5](#5-restore-cert-manager-and-re-issue-the-real-cert).

---

## 4. Option B

cert-manager is fully down and cannot create anything. Generate a self-signed cert
with `openssl` and write the `kubernetes.io/tls` Secret directly.

> **This is the most invasive path. Read [§4.4](#44-stop-argocd-from-fighting-you)
> about ArgoCD/cert-manager reverting your Secret BEFORE you start.**

### 4.1 Generate a self-signed wildcard cert (local, no cluster change yet)

Run on your workstation (WSL). `openssl` is standard on Ubuntu/WSL (verified
`OpenSSL 3.0.13` present); if missing, `sudo apt-get install -y openssl`.

```bash
cd /tmp
# Base tier example. For dev/stg, change every *.k8s to *.dev.k8s / *.stg.k8s.
openssl req -x509 -nodes -newkey rsa:2048 -days 7 \
  -keyout wildcard-k8s.key -out wildcard-k8s.crt \
  -subj "/CN=*.k8s.rommelporras.com" \
  -addext "subjectAltName=DNS:*.k8s.rommelporras.com,DNS:k8s.rommelporras.com"

# Sanity check the SANs and expiry:
openssl x509 -in wildcard-k8s.crt -noout -subject -ext subjectAltName -enddate
```

`-days 7` keeps this bridge intentionally short-lived so you don't forget to
replace it. This cert is **self-signed and untrusted** - browsers warn; you
click through. It only exists to keep TLS terminating until Let's Encrypt is back.

### 4.2 Write the Secret with the EXACT name the Gateway expects

> **WARNING - MUTATES CLUSTER STATE. The Secret name is load-bearing.** It must be
> exactly the name in the Gateway `certificateRefs` (`wildcard-k8s-tls`,
> `wildcard-dev-k8s-tls`, or `wildcard-stg-k8s-tls`) in the **`default`** namespace,
> type `kubernetes.io/tls`. A wrong name = the Gateway keeps serving the old
> expired cert.

The Secret already exists (it's just expired), so a plain `create` will fail with
`AlreadyExists`. Replace it in place with `create --dry-run | apply`:

```bash
# MUTATES CLUSTER STATE - overwrites the tls Secret with your self-signed cert.
kubectl-admin create secret tls wildcard-k8s-tls \
  --cert=/tmp/wildcard-k8s.crt --key=/tmp/wildcard-k8s.key \
  -n default --dry-run=client -o yaml | kubectl-admin apply -f -
```

(If for some reason the Secret does not exist, drop the `--dry-run | apply` and just
run the `kubectl-admin create secret tls ...` directly.)

Clean up the local key material afterwards:

```bash
shred -u /tmp/wildcard-k8s.key /tmp/wildcard-k8s.crt 2>/dev/null || rm -f /tmp/wildcard-k8s.key /tmp/wildcard-k8s.crt
```

### 4.3 Make the Gateway serve it

```bash
kubectl-admin rollout restart deployment/cilium-operator -n kube-system
```

Then verify ([§6](#6-verify)).

### 4.4 Stop ArgoCD (and cert-manager) from fighting you

Two possible reverters of your out-of-band Secret - understand both:

1. **cert-manager (if it partly recovers):** the Gateway-owned `Certificate`
   `wildcard-k8s-tls` still targets `secretName: wildcard-k8s-tls`. The moment
   cert-manager's controller comes back it will try to reconcile that Certificate
   and **overwrite your self-signed Secret** with a fresh ACME attempt (or an error
   state that blanks it). In Option B cert-manager is down, so this is dormant - but
   it's exactly what you *want* to happen in §5 (real cert reclaims the Secret). If
   cert-manager flaps back mid-outage and clobbers your bridge before ACME succeeds,
   pause it: `kubectl-admin scale deploy/cert-manager -n cert-manager --replicas=0`
   (remember to scale it back to `1` in §5).

2. **ArgoCD selfHeal:** this is the one people fear, but for these Secrets it is
   **not** a threat. The `gateway` ArgoCD app (`destination.namespace: default`)
   syncs path `manifests/gateway`, which contains **only** the Gateway and
   HTTPRoutes (`manifests/gateway/routes/`) - **no TLS Secret manifests**. The
   wildcard Secrets are produced by cert-manager at runtime and were never in Git,
   so they carry no ArgoCD tracking-id. ArgoCD prune only deletes resources it
   previously created and that have since vanished from Git; it will **not** prune a
   Secret it never owned. Your out-of-band Secret is therefore safe from ArgoCD.

   The only ArgoCD interaction is on the **Gateway annotation** if you removed it in
   Option A §3.3 - ArgoCD will re-add `cert-manager.io/cluster-issuer:
   letsencrypt-prod` on its next sync (that is the desired end state). If you need
   ArgoCD to leave the Gateway alone during the outage:
   ```bash
   # OPTIONAL - pause gateway auto-sync so it stops re-adding the annotation.
   # RE-ENABLE in §5.
   kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
     argocd app set gateway --sync-policy none --core
   ```

---

## 5. Restore cert-manager and re-issue the real cert

Once HTTPS is limping along on the bridge cert, fix the actual root cause and let
Let's Encrypt take back over. **Do not thrash the ACME path - respect rate limits.**

### 5.1 Fix cert-manager itself

- **Controller/webhook crashed:** check why, then let ArgoCD re-sync the Helm app.
  ```bash
  kubectl-admin get pods -n cert-manager
  kubectl-admin -n cert-manager logs deploy/cert-manager --tail=100
  kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
    argocd app sync cert-manager --core
  kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
    argocd app sync cert-manager-manifests --core
  ```
  If you scaled the controller to 0 in §4.4, scale it back:
  `kubectl-admin scale deploy/cert-manager -n cert-manager --replicas=1`.
- **Cloudflare token expired (the usual real cause):** rotate the Cloudflare DNS
  API token. It lives in Vault at `cert-manager/cloudflare-api-token` and in
  1Password ("Cloudflare DNS API Token"), surfaced by the ESO ExternalSecret in
  `manifests/cert-manager/externalsecret.yaml` (name `cloudflare-api-token`) as
  Secret `cloudflare-api-token` in ns `cert-manager` (key `api-token`). Rotate per
  [managing-secrets.md](managing-secrets.md), then force-sync ESO. cert-manager
  retries the DNS-01 challenge automatically once the token is valid.

### 5.2 Undo the temporary break-glass objects

> **MUTATES CLUSTER STATE.** Remove everything you added so the Gateway shim + real
> ACME cert can own the Secret again.

```bash
# Option A cleanup - remove the temp Certificate + ClusterIssuer:
kubectl-admin delete certificate wildcard-k8s-breakglass -n default
kubectl-admin delete clusterissuer selfsigned-breakglass

# If you removed the Gateway annotation in §3.3, restore it (or let ArgoCD do it):
kubectl-admin annotate gateway homelab-gateway -n default \
  cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite

# If you paused gateway auto-sync in §4.4, re-enable automated sync (self-heal + prune):
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd app set gateway --sync-policy automated --self-heal --auto-prune --core
```

### 5.3 Trigger the real Let's Encrypt reissue

With cert-manager healthy and Cloudflare reachable, delete the (self-signed) backing
Secret. The Gateway-owned Certificate reconciles and cert-manager requests a fresh
**Let's Encrypt production** cert via DNS-01. This is the same one-liner as the
normal fix.

> **WARNING - this hits Let's Encrypt production. Do it ONCE.** Repeated deletes
> re-request duplicate certs and can trip the ~5 duplicate-certs / 168h limit,
> locking you out of new certs for up to a week. If you're unsure it'll succeed, dry
> run against `letsencrypt-staging` first (issues an untrusted cert, no prod limit).

```bash
# MUTATES CLUSTER STATE - forces a real ACME reissue for the base tier:
kubectl-admin delete secret wildcard-k8s-tls -n default

# Watch cert-manager mint the real cert (READY -> True, then check the SAN/issuer):
kubectl-admin get certificate wildcard-k8s-tls -n default -o wide
kubectl-admin get order,challenge -A          # DNS-01 challenge should validate then vanish
kubectl-admin -n cert-manager logs deploy/cert-manager --tail=50
```

Repeat for `wildcard-dev-k8s-tls` / `wildcard-stg-k8s-tls` **only** if those were
also broken.

---

## 6. Verify

```bash
# 1. Secret exists, correct type (do NOT use -o yaml - RBAC leaks values):
kubectl-admin get secret -n default | grep wildcard

# 2. Certificate READY:
kubectl-admin get certificate -n default -o wide

# 3. What is actually being served? Check issuer + expiry over the wire:
echo | openssl s_client -connect 10.10.30.20:443 \
  -servername homepage.k8s.rommelporras.com 2>/dev/null \
  | openssl x509 -noout -issuer -subject -enddate
```

- Bridge cert in place: issuer will be self-signed (`CN=*.k8s.rommelporras.com`),
  browser warns but the site loads.
- Real cert restored: issuer is `Let's Encrypt` and browsers stop warning.
- From a real LAN browser, hard-reload `https://homepage.k8s.rommelporras.com` and
  confirm the padlock (Let's Encrypt) after §5.

> `10.10.30.20` is the Cilium Gateway VIP serving all `*.k8s.rommelporras.com`.
> Use `-servername` for the tier you're testing (`*.dev`/`*.stg` for those Secrets).

---

## 7. Tell the AI when it's back

Report, in order: which option (A/B) you used; every object you created or mutated
(the temp ClusterIssuer/Certificate, the hand-written Secret, any Gateway
annotation removal or ArgoCD sync-policy change); and whether the real Let's Encrypt
cert has reclaimed each Secret. Anything created out-of-band that is still present
(temp issuer/cert, a paused ArgoCD app, a scaled-down cert-manager) needs cleaning
up and reconciling back into the Git-declared state.

---

## Related

- [../runbooks/00-EMERGENCY.md §4.1](../runbooks/00-EMERGENCY.md#41-tls-certificate-problems) - normal TLS triage (try first)
- [../runbooks/certificates.md](../runbooks/certificates.md) - cert-manager alert runbook
- [../context/Gateway.md](../context/Gateway.md) - Gateway, HTTPRoutes, TLS listeners
- [managing-secrets.md](managing-secrets.md) - Vault/ESO, Cloudflare token rotation
- [../runbooks/vault.md](../runbooks/vault.md) - Vault sealed / ESO not syncing

