# AppPort contract knowledge

fx reads AppPort contracts natively. An AppPort contract is an application
manifest as defined by `@appport/protocol`, with optional integration
metadata in `attributes["appport.integration/1"]`. fx checks a contract,
derives its declared capability graph, selects capabilities, and prepares
compact model context in Zig. None of this calls a model, and the fx binary
never loads Node.js, npm, or the AppPort JavaScript packages.

The published AppPort packages remain the authority. fx embeds a small
representation of the semantics listed under [Coverage](#coverage) and checks
it against pinned package versions with a development-time parity suite.

## Inspect contracts

```bash
fx appport inspect docs.json billing.json
fx appport inspect docs.json --json
```

Each contract gets a SHA-256 digest of the exact bytes read and one verdict:

| Verdict | Meaning |
| --- | --- |
| `valid` | Every check fx runs passed. |
| `unsupported` | The contract uses something fx does not interpret, such as another protocol id, an unknown extension, or an unknown top-level field. |
| `inconsistent` | Declarations contradict each other, such as a dependency on an undeclared capability or a required synchronous cycle. |
| `incomplete` | A required field is missing. |
| `malformed` | The document is not JSON, or a field has the wrong shape or value. |

`inspect` exits with status 1 unless every contract is `valid`. When a
contract is malformed or incomplete, fx skips the dependency checks and says
so, because the reference checks cannot process those shapes.

Each diagnostic names its source. `appport.lintDependencyModel` diagnostics
come from the native port of that `@appport/protocol` function and use the
reference paths and messages. `fx.structure` diagnostics come from fx's own
checks against the published `AppPortManifest` types, because the AppPort
packages publish no structural manifest validator.

A `valid` verdict covers only the checks fx runs. Every report lists what fx
did not check, including `lintIntegration`, `lintAgentContract`, JSON Schema
validity, digests, signatures, and runtime behavior.

## Derive the capability graph

```bash
fx appport graph docs.json billing.json --json
```

The graph follows `deriveGraph` from `@appport/integration` for published
manifests. It reports every edge with `declared` provenance, along with
unresolved targets, coverage gaps, ownership conflicts, writes to resources
another application owns, and required synchronous cycles. fx does not accept
mapping artifacts, inferred or observed findings, or observation coverage, so
it never reports `data-flow` edges or observation unknowns.

## Find capabilities

```bash
fx appport find docs.json billing.json --changes urn:example:docs:document --operation update
```

`find` follows `findCapabilities`. It matches only published fields:
`--application`, `--capability`, `--reads`, `--changes`, `--operation`, and
`--effect-type`. A capability without an integration entry is listed as
undeclared, which means unknown, not a non-match. `--concept` is not
supported and fails with `UnsupportedSelector`.

`fx appport plan`, `compare`, and `assess` fail with `UnsupportedOperation`.
fx does not approximate `planIntegration`, `compareBehavior`, or
`assessReplacement`.

## Give the model AppPort context

```bash
FX_APPPORT_MANIFEST=contracts/docs.json,contracts/billing.json \
FX_APPPORT_FOCUS=docs.save \
fx ask "Add a retry to the document save flow"
```

When `FX_APPPORT_MANIFEST` names one or more contract files, fx adds one
system message to each model request. The message holds the contract facts
for the selected capabilities: kind, effect, authorization, input and output
fields, dependencies, state access, approval, preconditions, failure
behavior, declared verification methods, unknowns, and risks. Relative paths
resolve against the directory fx starts in.

`FX_APPPORT_FOCUS` takes comma-separated capability names or `name@version`
references. fx includes those capabilities and the same-application
capabilities they depend on or verify through. Without a focus, fx includes
every capability up to a 16 KiB limit and lists the rest by name.

The message states the evidence rules the model must follow: a declaration, a
plan, or a model answer is not proof of execution; declared compatibility is
not behavioral equivalence; and effects are confirmed only through declared
verification methods. Publisher-written descriptions and purposes are quoted
as data on single lines.

When `FX_APPPORT_MANIFEST` is unset, fx adds nothing and requests are
unchanged. A contract that cannot be read becomes a one-line notice in the
message instead of failing the turn. The context reaches every provider
through the same request path as other system context.

Preview the exact text with:

```bash
fx appport context docs.json billing.json --focus docs.save
```

## Coverage

`fx appport coverage` lists what the native knowledge covers:

| Status | Semantics |
| --- | --- |
| Ported, parity-tested | `validateName`, `isValidApplicationId`, `isValidPermission`, `isSupportedProtocol`, `isVersionConstraint`, `satisfiesVersionConstraint`, `parseDependencyRef`, `lintDependencyModel`, `deriveGraph` over published manifests, `findCapabilities` without `concept` |
| fx-native | Manifest structure against the `AppPortManifest` types |
| Not supported | `lintIntegration`, `lintAgentContract`, `validateSemanticAnnotations`, JSON Schema validation, digests and signatures, mappings and findings, `concept` selectors, `planIntegration`, `compareBehavior`, `assessReplacement` |

Reference versions: `@appport/protocol` 1.1.0 and `@appport/integration`
1.1.0. fx sorts graph output by byte order where the reference uses
`localeCompare`; the content is the same.

## Parity checks

`tests/appport-parity/` compares fx with the published packages. It is a
development-time suite with its own pinned dependencies and is never part of
the fx binary.

```bash
zig build
cd tests/appport-parity && bun install && bun test
```

The suite fails when:

- an installed reference version differs from the pins in
  `src/core/appport/appport.zig`;
- a reference source file differs from the digest recorded in
  `reference-digests.json`;
- fx and the reference disagree on any supported case. The cases include the
  checked-in fixtures, manifests generated by `@appport/server`, a manifest
  loaded over HTTP by `@appport/client` through `@appport/transport-http`,
  and 600 seeded mutations of the fixtures;
- fx answers an unsupported case instead of reporting it.

To adopt a new AppPort release, update the pins in `package.json` and
`appport.zig`, review the reference changes, update the native port, and then
record the new digests.
