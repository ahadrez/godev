# Centralized Secrets Management for On-Premises OpenShift — TDD

| Document metadata | Value |
|---|---|
| Document type | Technical Design Document (TDD) |
| Version | **1.1 — validated working copy** (supersedes v1.0 draft of 6 Nov 2026) |
| Date | 6 November 2026 |
| Status | Proposed; production authorization and security review pending |
| Primary owners | OpenShift Platform / GCP Security |
| Scope | On-premises OpenShift applications, DEV / TEST / PROD |

**Design principle:** keep OpenShift multi-tenant; centralize secret delivery; enforce platform ownership of secret references.

**Production caveat (unchanged, verified against Google's docs):** the Google provider's `provider-adc` mode shares one identity for all workloads and is explicitly not recommended by Google for production due to absent namespace isolation. This design compensates with OpenShift controls and requires formal risk acceptance; it does not claim per-application GCP IAM.

## What changed in v1.1

1. Every claim is tagged **[VERIFIED]** (demonstrated on the PoC cluster or confirmed in official docs, dates below) or **[PENDING]** (evidence still required).
2. Placeholders replaced with as-built values where they exist.
3. §4.2 ServiceAccount-name hazard resolved: all artifacts now use the deployed name `secrets-store-csi-driver-provider-gcp` (the older runbook's `csi-provider-gcp` has been corrected).
4. Gap-analysis results (6 Nov 2026) merged into §12–§14; implementation plan re-prioritized P0/P1/P2.
5. New ADR-09: WIF pool currently lives in the application project, not the identity project.

## 1. Executive design summary

Three shared Secret Manager projects — DEV, TEST, PROD — administered under the Security team's GCP folder serve all on-prem OpenShift applications. The Red Hat-managed Secrets Store CSI Driver calls a separately deployed Google Secret Manager CSI provider; application pods consume secret values as read-only files. No Kubernetes Secret synchronization. **[VERIFIED 2 Nov 2026** on cluster `ocpb.enp.aramco.com.sa`, namespace `ucod-hadrezak-sandbox`: mount working, `oc get secrets` empty**]**

Each cluster has its own WIF pool + OIDC provider (existing issuer, uploaded JWKS). The provider authenticates with its own projected token (`provider-adc`); IAM grants `roles/secretmanager.secretAccessor` per individual secret only. **[VERIFIED]**

Namespace admins deploy their own apps; a cluster-wide ValidatingAdmissionPolicy restricts SecretProviderClass writes to the platform group. **[PENDING — not yet implemented; see §13 P0]**

### 1.1 Design status

| Area | Decision | Status |
|---|---|---|
| Functional CSI + WIF | `provider-adc`, one pool per cluster | **[VERIFIED]** working end-to-end 2 Nov 2026 |
| Shared GCP projects | 3 projects by environment under Security folder | **[PENDING]** — PoC secret lives in app project `udc-d-30049622-stella-1` |
| Secret-level IAM | per-secret grants only | **[VERIFIED]** binding exists at secret level; **[PENDING]** project-wide-grant audit + stale-binding cleanup |
| SPC ownership | platform-only via VAP | **[PENDING]** — VAP not deployed; ns admin can currently write SPCs |
| Restricted app namespaces | no privileged app namespaces | **[PENDING]** — app ns currently privileged (workaround); CSIDriver-label investigation open (ADR-06) |
| Tenant authorization | OpenShift-enforced; GCP sees one shared provider identity | Conditional / residual risk — requires §12 evidence + sign-off |

## 2. Design drivers and scope

**In scope:** Security-folder project structure; secret-level IAM; RH driver + Google OSS provider on the existing estate; keyless WIF over private connectivity; platform-controlled SPC + native VAP + negative testing; file-consumption contract, rotation, audit, operating model.

**Out of scope (unchanged):** per-application clusters; per-application CSI identities or custom providers; ESO / any sync into Kubernetes Secrets; app changes beyond file consumption and reload.

### 2.3 Non-functional requirements

| ID | Requirement | v1.1 status |
|---|---|---|
| NFR-01 | No long-lived GCP keys; short-lived projected tokens only | **[VERIFIED]** — external_account config holds pointers only |
| NFR-02 | No secrets in etcd; no syncSecret | **[VERIFIED]** — negative check passed |
| NFR-03 | App namespaces restricted/baseline; provider elevation documented and scoped | **[PENDING]** — see ADR-06 |
| NFR-04 | Private connectivity to Google APIs | **[PENDING]** — path not yet evidenced; see §8 |
| NFR-05 | Documented ops procedures + SLOs | **[PENDING]** |
| NFR-06 | Ns admin deploys apps but cannot modify secret references | **[PENDING]** — blocked on VAP |

## 3. Architecture and topology

Unchanged from v1.0 (Figure 1): app namespaces hold per-app SecretProviderClasses and CSI-mounted workloads; the RH driver and the Google provider DaemonSet run in `openshift-cluster-csi-drivers`; one WIF pool/provider per cluster; three shared secret projects under the Security folder.

**As-built note [VERIFIED]:** provider DaemonSet `csi-secrets-store-provider-gcp` runs in `openshift-cluster-csi-drivers` with the `privileged` SCC and `privileged: true` on both containers (SELinux requirement for the hostPath socket — documented elevation per NFR-03, scoped to the system namespace). Socket dir `/var/run/secrets-store-csi-providers`, matched to the RH driver's `--provider-volume`.

## 4. Secrets request and WIF identity flow

Unchanged (Figure 2): pod requests CSI volume → driver reads SPC → provider (`provider-adc`) exchanges its projected token at Google STS → Secret Manager authorizes the provider principal at the secret's IAM policy → file materializes in tmpfs. **[VERIFIED end-to-end]**

### 4.1 Credential chain — [VERIFIED], with these as-built values

| Element | As-built value |
|---|---|
| WIF pool / provider | `ocp-csi-poc` / `ocp-lab1` (PoC names; production naming TBD) |
| Issuer | `https://kubernetes.default.svc` (cluster default; allowed by project-scoped org-policy override) |
| JWKS | uploaded via `--jwk-json-path` (no public issuer endpoint) |
| Audience | `https://ocp-csi-poc.example.invalid` — **placeholder; production audience decision open (§5.4)** |
| Subject condition | `assertion.sub == 'system:serviceaccount:openshift-cluster-csi-drivers:secrets-store-csi-driver-provider-gcp'` |
| Auth mode | `auth: provider-adc` in every SPC — **mandatory off-GKE** (default pod-adc calls a GKE-only API; fails `400` on-prem) **[VERIFIED]** |

### 4.2 Identity

```
system:serviceaccount:openshift-cluster-csi-drivers:secrets-store-csi-driver-provider-gcp
```

Resolved in v1.1: this deployed name is now used consistently across scripts, WIF condition, IAM member and documentation. Any future rename of the provider ServiceAccount requires a coordinated WIF + IAM change.

## 5. GCP project and IAM design

### 5.1 Shared project structure — [PENDING]

`ocp-secrets-dev|test|prod` under the approved Security folder (names via LZ project factory conventions). Note from the LZ build-out: these projects need **only** region-policy compliance; the `iam.workloadIdentityPoolProviders` override is needed only where the WIF pool lives.

### 5.2 Secret naming and ownership — [PENDING]

`<application>-<purpose>` (e.g. `ap-db-password`) + ownership registry (environment, namespace, owner, rotation strategy, approved SPC). The PoC secret `csi-poc-password` does not follow this and is to be retired.

### 5.3 Least-privilege IAM — [VERIFIED mechanism / PENDING hygiene]

Grant `roles/secretmanager.secretAccessor` to the federated provider principal **per secret** only (illustrative command unchanged from v1.0, with the §4.2 subject). Outstanding hygiene **[PENDING]**: (a) remove the stale binding for the obsolete subject `...:ucod-hadrezak-sandbox:secrets-store-csi-driver-provider-gcp` on the PoC secret; (b) one-time audit confirming no project-level accessor grants exist.

### 5.4 WIF isolation — [VERIFIED as built, two open items]

One pool + provider per cluster; immutable mappings; exact-subject attribute condition — all in place. Open: production **audience** value (replace the placeholder; prefer a reviewed canonical audience), and **JWKS refresh** procedure on cluster key rotation (ADR-08 — currently manual).

## 6. OpenShift component design

### 6.1 / 6.2 Driver and provider baseline — [VERIFIED as built, one deviation]

RH operator manages the driver; Google OSS provider is a separate DaemonSet in `openshift-cluster-csi-drivers`; no secret sync; external_account ConfigMap contains no key material. **Deviation [PENDING fix]:** images are mutable tags (`quay.io/upstream/secrets-store-csi-driver-provider-gcp:v1.8.0`, init `ubi9/ubi-minimal:latest`); production requires digest-pinning both and registry approval. Preserve the proven provider security configuration (privileged containers, SCC, socket path) until the controlled hardening test described in v1.0 — unchanged.

### 6.3 Application namespace security — [PENDING, investigation ordered]

Target: app namespaces at restricted/baseline. As-built: `ucod-hadrezak-sandbox` carries `pod-security.kubernetes.io/enforce=privileged` — a PoC workaround, **not accepted as standard**. Open investigation (ADR-06): confirm the `security.openshift.io/csi-ephemeral-volume-profile` label on `CSIDriver/secrets-store.csi.k8s.io` is the cause (OpenShift treats unlabeled/privileged-labeled drivers as requiring privileged namespaces for inline volumes); if so, relabel to `restricted` after review, revert the namespace to restricted, add restricted-PSS fields to pod specs, pass T-10. Verification commands unchanged from v1.0 §6.3.

## 7. Admission control and multi-tenant authorization

Model unchanged (Figure 3): VAP denies SPC CREATE/UPDATE/DELETE unless requester is in `platform-secrets-admins`; GCP IAM limits what the shared provider identity can read at all.

**Platform availability [VERIFIED]:** ValidatingAdmissionPolicy is GA from Kubernetes 1.30 / OpenShift 4.17 (`admissionregistration.k8s.io/v1`). Confirm cluster version during P0 (presence of `restricted-v3` SCC on the PoC cluster indicates ≥ 4.18).

**Current state [VERIFIED]:** no VAP exists; a namespace admin can write SPCs today. T-02/03/04 currently fail by construction.

7.1–7.4 unchanged from v1.0, including: RBAC is additive (hence admission, not RBAC, is the control); rollout Warn/Audit → Deny; policy cannot bind on app-controlled labels; cluster-admin is out of scope of VAP and must be governed by change control; bypass testing per §7.3 is mandatory (test battery: own-ns mount allowed by design; cross-ns SPC reference; `nodePublishSecretRef`/volumeAttributes smuggling; hostPath/privileged attempts from app ns; system-ns token/socket access; group-claim validation in Warn phase).

## 8. Network, data residency and trust boundaries

Unchanged target: private connectivity to `sts.googleapis.com` and Secret Manager; data residency `me-central2`.

**As-built [VERIFIED]:** the PoC secret uses user-managed replication pinned to `me-central2` (forced by `gcp.resourceLocations`); functional connectivity from nodes exists. **[PENDING]:** evidence of *which* egress path (private/restricted Google APIs vs public), and ADR-05. **Validated constraint:** Google documents that regional Secret Manager endpoints (`secretmanager.me-central2.rep.googleapis.com`) do **not** support Private Google Access — PSC would be required for regional-endpoint mode. The current PoC uses the global API with region-pinned replication; keep that unless Security mandates regional endpoints, in which case plan PSC.

## 9. Application integration contract

Unchanged from v1.0 (standard SPC with `auth: provider-adc`; read-only volume; developer obligations §9.3). **[VERIFIED]** for the reference app (`goapp-sm`): reads `/mnt/secrets/password`, re-reads per request. **Production deltas [PENDING]:** remove `ALLOW_REVEAL` (demo-only; code default is off — enforce via env overlay) and the demo status page per §9.3/15.3.

## 10. Rotation, reliability and operations

Unchanged tables (10.1 rotation patterns, 10.2 failure modes, 10.3 monitoring). **As-built [VERIFIED]:** driver runs `--enable-secret-rotation=true --rotation-poll-interval=2m`; rotation observed end-to-end on **GKE** and locally. **[PENDING]:** T-11 observed on the OpenShift cluster (version add → file update → app reload) before quoting any SLO; T-12 revocation drill; Data Access audit logs enabled and routed; alerting; reconciliation cadence.

## 11. Threat model and residual risk

Unchanged from v1.0, including the security acceptance requirement: Google's documentation explicitly warns against `provider-adc` in production (verified); SPC protection is a compensating OpenShift control, not a removal of that limitation. Security must accept the residual risk in writing or require an identity-isolated provider design before production.

## 12. Validation and production acceptance

Test matrix unchanged; v1.1 adds current status:

| Test | Description | Status |
|---|---|---|
| T-01 | Platform admin creates SPC; mount succeeds | Mechanism **[VERIFIED]** (mount works); platform-group path **[PENDING]** |
| T-02/03/04 | Ns admin create/patch/delete SPC → DENY | **[PENDING]** — fails today (no VAP) |
| T-05 | Ns admin mounts own approved SPC | **[VERIFIED]** (accepted by design) |
| T-06/07 | Cross-ns SPC / alternate CSI config paths | **[PENDING]** — must be demonstrated, not assumed |
| T-08 | Provider reads un-granted secret → PermissionDenied | Observed once during build **[VERIFIED-informal]**; repeat formally |
| T-09 | DEV principal vs PROD secret | **[PENDING]** — requires shared projects (ADR-04) |
| T-10 | Restricted app namespace + CSI | **[PENDING]** — ADR-06 |
| T-11/12 | Rotation observed / revocation drill | **[PENDING]** on OpenShift |
| T-13 | Image digest + audit logs | **[PENDING]** |

Go/No-Go criteria unchanged from v1.0 §12.2.

## 13. Implementation plan (re-prioritized, minimal-change)

**P0 — compensating controls (gate for everything else)**
1. Close ADR-06: run the four read-only CSIDriver checks; if confirmed, relabel driver profile to `restricted`, revert app ns labels, add restricted-PSS pod fields, pass T-10.
2. `platform-secrets-admins` group + RBAC; VAP from §15.1 in `[Warn, Audit]` on DEV; verify real group claims; flip to `[Deny]`; pass T-01–T-04.
3. Bypass battery (§7.3) → T-05–T-08 with captured evidence.
4. IAM hygiene: remove stale binding; project-wide-grant audit; enable Secret Manager Data Access logs now.

**P1 — production foundation**
5. Shared projects `ocp-secrets-dev|test|prod` via LZ project factory; migrate/retire PoC secret; decide ADR-04 before any PROD grant; decide ADR-09 (pool location).
6. Digest-pin provider + init images; registry approval.
7. Env overlay removing `ALLOW_REVEAL`; production audience (5.4); naming + ownership registry (5.2).

**P2 — operational readiness**
8. T-11/T-12 on OpenShift; publish §9.3 as the onboarding contract; set rotation SLO from observed behavior.
9. JWKS refresh automation (ADR-08).
10. Monitoring/alerting per 10.3; reconciliation cadence.
11. Risk-acceptance package (threat model + evidence) → Security/ARB sign-off (ADR-07).

Ownership stages 1–8 and rollout/rollback approach unchanged from v1.0 §13/§13.1.

## 14. Open decisions / ADRs

| ID | Decision | Owner | v1.1 status |
|---|---|---|---|
| ADR-01 | Three shared projects under Security folder | Agreed | Unbuilt (P1) |
| ADR-02 | Multi-tenant namespaces, ns-admin workflow | Agreed | In effect |
| ADR-03 | Native VAP for SPC protection | Platform | Validated available (OCP ≥ 4.17); unimplemented (P0) |
| ADR-04 | Cluster↔environment identity mapping / cross-env trust | Platform + Security | Open; blocks PROD grants |
| ADR-05 | me-central2: user-managed global vs regional endpoints (+PSC) | GCP Security | Open; PGA limitation for regional endpoints confirmed |
| ADR-06 | Restricted CSI admission profile; remove privileged app ns | OpenShift Platform | Investigation specified, evidence pending |
| ADR-07 | provider-adc production exception | Security / ARB | Open; required for Go |
| ADR-08 | Rotation interval, reload contract, JWKS refresh automation | Platform + App Teams | Open |
| ADR-09 *(new)* | WIF pool location: currently in app project `udc-d-30049622-stella-1`; TDD target is a Security-owned identity project. Move pool (re-issue provider config + IAM) or formally accept current location. | Security | Open |

## 15. Configuration appendix

15.1 VAP example and 15.2 verification commands unchanged from v1.0. 15.3 PoC-to-production checklist unchanged, with v1.1 status: ALLOW_REVEAL (open), PoC secret replacement (open), platform-provisioned SPC (open), image digest pinning (open), **SA-name reconciliation (done)**, privileged-label removal (open, ADR-06).

## 16. Official references — validation log (6 Nov 2026)

| Claim | Source | Result |
|---|---|---|
| provider-adc not recommended for production (no namespace isolation) | Google OSS provider `authentication.md` | Confirmed |
| WIF for self-managed Kubernetes: uploaded JWKS, no public issuer required | Google WIF-with-Kubernetes guide | Confirmed (and used as-built) |
| VAP GA | Kubernetes 1.30 release notes / OpenShift API GA promotion (4.17) | Confirmed |
| Regional SM endpoints incompatible with Private Google Access | Google regional-secrets connectivity docs | Confirmed |
| End-to-end mount, etcd-clean, provider-adc requirement, SCC/SELinux behavior, org-policy interactions | Live PoC, this repo + `udc/` kit, 27 Oct – 2 Nov 2026 | Demonstrated |

Full reference URLs unchanged from v1.0 §16.
