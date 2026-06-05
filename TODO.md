# TODO

## JAVA_TOOL_OPTIONS must not be overwritten in service configmaps

**Context:** ABN `saveHint` from partnersync always returned 401. Root cause: `JAVA_TOOL_OPTIONS` was overwritten in the service configmap, removing the corporate proxy and no-proxy settings set by the base Docker image. Without the proxy, the service could not reach the ABN IDP → JWT issuer discovery failed → all authenticated requests returned 401.

**Known issue — already in ELPA wiki.**

**Rule:**
- `JAVA_TOOL_OPTIONS` → owned by SI base image (truststore, proxy, no-proxy). **Never set this in configmaps or Helm values.**
- `JDK_JAVA_OPTIONS` → safe for application-level JVM flags (RAM%, GC, Spring profile, Kafka OAuth URL)

**Fix:** Move `-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=...` and any other service JVM flags to `JDK_JAVA_OPTIONS`.

**Audit:** Check all ELPA service Helm configmap templates for `JAVA_TOOL_OPTIONS` entries that override the base image value.

```yaml
# WRONG — overwrites base image proxy+truststore:
JAVA_TOOL_OPTIONS: "-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls={{ .Values.kafka.oauthTokenEndpoint }}"

# CORRECT:
JDK_JAVA_OPTIONS: "... -Dorg.apache.kafka.sasl.oauthbearer.allowed.urls={{ .Values.kafka.oauthTokenEndpoint }}"
```

---

## ELPA Jenkins Shared Lib — Deploy Workflow Edge Cases

**Context:** `elpa-elpa4` CD repo had a broken `kustomization.yaml is empty` ArgoCD error after ELPA4-588 abn deploy.
**Files to fix:** `ELPA/jenkins-shared-lib` → `vars/elpa_copsi.groovy`

---

### Bug 1 — CRITICAL: Empty kustomization after last feature cleanup

**Location:** `cleanupObsoleteFeatures()` ~L228

When all feature files are obsolete and removed, `removeKustomizeResource(serviceDir, "features")` strips the last entry from `kustomization.yaml`, leaving it empty. ArgoCD then fails: `kustomization.yaml is empty`.

Triggered when: service kustomization only has `resources: [features]` (no `abn.yaml`/`tst.yaml`) and all feature branches are deleted.

```groovy
// CURRENT (broken):
if (remainingCount == 0) {
    deleteDirectory(featureDir)
    removeKustomizeResource(serviceDir, "features")
    // nothing ensures abn.yaml + tst.yaml stay registered
}

// FIX:
if (remainingCount == 0) {
    deleteDirectory(featureDir)
    removeKustomizeResource(serviceDir, "features")
    addKustomizeResource(serviceDir, "abn.yaml")
    addKustomizeResource(serviceDir, "tst.yaml")
}
```

---

### Bug 2 — HIGH: deployTst / deployAbn never register their file in kustomization

**Location:** `deployTst()` L45, `deployAbn()` L53

Both functions write `tst.yaml` / `abn.yaml` but pass `null` as `afterDeployManifest`, so they never call `addKustomizeResource`. On a fresh migration or initial setup the kustomization won't list them and ArgoCD silently skips those environments.

```groovy
// FIX in deployTst:
Closure<Void> afterDeployManifest = {
    addKustomizeResource("${SERVICE_TARGET_DIR}/${serviceName}", "tst.yaml")
}
return deployManifest(serviceName, jiraTicket, "tst", renderedYaml,
    "${SERVICE_TARGET_DIR}/${serviceName}/tst.yaml", afterDeployManifest, CopsiEnvironment.nop)

// same pattern for deployAbn (abn.yaml)
```

---

### Bug 3 — MEDIUM: addKustomizeResource uses substring match for dedup

**Location:** `addKustomizeResource()` L374

`kustomizationContent.contains(resourceName)` is a substring check. A resource named `tst.yaml` would be skipped if the content already contains `values-tst.yaml`.

```groovy
// CURRENT (imprecise):
if (kustomizationContent.contains(resourceName)) { return }

// FIX (exact line match):
if (kustomizationContent.readLines().any { it.trim() == "- ${resourceName}" }) { return }
```
