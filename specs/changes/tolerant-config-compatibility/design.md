# Design: tolerant-config-compatibility

## Approach

Use a typed compatibility issue collector rather than scattering policy decisions across direct warning calls. Admission and resolution classify top-level properties; existing runArgs, Feature, image-metadata, and bounded-emulation paths contribute to the same issue vocabulary. The collector deduplicates issues and presents each completed evaluation boundary in deterministic order. Runtime DTOs continue to contain only effective behavior, so ignored raw input never leaks into Apple create argv or identity material.

The alternative of changing unknown-property rejection into a universal warning was rejected because a typo and a future security/workspace selector are indistinguishable without a registered semantic classification. The alternative of passing unknown flags to Apple `container` was rejected because Docker spelling does not establish Apple semantic equivalence and because product-owned identity, mounts, labels, user, workdir, and entrypoint must remain protected.

## Significant decisions

### Registry and dispositions

The compatibility registry records the recognized property or input family and one of four outcomes:

| Disposition | Meaning |
|-------------|---------|
| Exact | Normalize into the typed effective model; no compatibility issue |
| Emulated | Deliver a bounded substitute; report the semantic difference |
| Ignored | Remove known optional behavior; report what is absent |
| Blocked | Return a structured error because no safe/coherent effective result exists |

Harmless metadata is an explicit silent class adjacent to these dispositions: it is admitted, unused, and hash-neutral without implying runtime behavior. It is not a fallback for unknown input. `$schema` and `overrideCommand: true` belong here: true restates the product default keep-alive and MUST NOT be treated as an exact translation that adds hash material.

### Strict gate

Default mode emits compatibility warnings and proceeds. Strict mode converts any emulated or ignored issue into `compatibility_degraded`. It does not reject exact translations or harmless metadata. Config-level issues are gated after effective config resolution and before create/start/reuse/user exec. Issues that require Feature or image metadata inspection are gated after metadata is available and before derived-image build, container create, or a bare-start lifecycle action. Strict bare-start performs an opt-in preflight rather than swallowing compatibility failures through the default best-effort hook loader. Read-only discovery needed to classify the input may occur before the gate.

### Warning ordering and cardinality

An issue identity is its stable code, property path, and non-secret subject identity. Duplicate pre-substitution/post-substitution admission and repeated merge inspection collapse to one issue. File-bind promotions use one emulated issue per promoted bind. A completed evaluation boundary sorts by property path, then code, then safe subject identity before emission or strict-error aggregation. This provides deterministic output without requiring warnings discovered only after Feature fetch to appear before earlier config-resolution warnings. Sidecar notices such as the extra NET_ADMIN contextual warning remain outside the issue vocabulary and do not by themselves fail strict mode.

### Hashing

Hash material is derived from the normalized effective model. Top-level `capAdd` and equivalent `runArgs --cap-add` normalize to the same capability entries and therefore the same config-time hash material. Existing Feature references/options remain independent identity inputs even when their runtime capability contribution deduplicates. Ignored properties, harmless metadata, issue text/codes, and strict mode are excluded. An emulation hashes the delivered behavior, not unsupported raw syntax.

## Flow

```text
JSONC input
  -> structural admission and registered-property classification
  -> substitution
  -> effective config normalization + config compatibility issues
  -> deterministic warning emission OR strict config gate
  -> optional Feature/image metadata resolution + additional issues
  -> deterministic warning emission OR strict metadata gate
  -> typed CreateRequest
  -> Apple container runtime
```

Errors for malformed or blocked semantics bypass degradation reporting and retain their specific structured property/error code. Strict degradation is distinct: the input is structurally valid and has a known tolerant outcome, but the caller requested no degradation.

## Architectural boundaries

- Configuration owns the registry, issue/report value types, top-level classification, deduplication, sorting, and config hash normalization.
- Feature and runArgs parsers report typed issues instead of deciding terminal presentation directly.
- StatusPrinter remains the stderr presentation adapter and retains QUIET/JSON channel behavior.
- Commands choose compatibility mode, carry the report through later metadata resolution, and enforce the appropriate gate before runtime effects.
- AppleContainerRuntime and CreateRequest receive only typed effective fields; neither interprets raw Dev Container properties.

## Migration and rollback

Configurations containing the newly recognized low-risk properties change from immediate unsupported-property failure to exact, silent, or warning-backed success. Top-level `capAdd` changes effective hash material; an existing managed container resolved from a newly edited capability declaration requires rebuild under the existing hash-mismatch policy. Metadata-only and warn-stripped inputs remain hash-neutral. Rolling back the change restores prior admission failures but does not require data migration; containers created with effective capabilities retain those create-time settings until rebuilt.

Warning text becomes stable-code based. Tests and downstream scripts should key on the code rather than the full prose. Strict mode is opt-in so existing automation remains tolerant unless it explicitly requests degradation failure.

## Security considerations

No compatibility disposition may invent privilege, expose a device, weaken a read-only request, redirect a workspace, choose an undeclared image, or pass raw arguments. `privileged: true` remains unapplied and visible; it is never translated to Apple virtualization. `secrets` is recommendation metadata only: issue output must not enumerate keys or values. Strict-mode aggregated errors carry codes and property paths but no raw secret, mount-source, credential, or security-option values unless an existing redaction contract already permits a safe identifier.
