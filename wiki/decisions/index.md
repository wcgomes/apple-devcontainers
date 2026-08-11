# Decisions (ADRs)

| ADR | Summary |
|-----|---------|
| [0001](0001-greenfield-swift-cli.md) | Greenfield Swift CLI; sole runtime = Apple container |
| [0002](0002-reject-docker-ood-privileged-tun.md) | Original reject policy; **superseded in part** by 0003 for optional incompatibles; Compose/unknown still fail-closed |
| [0003](0003-warn-skip-apple-incompatibles.md) | Warn-skip docker-* features, privileged/device runArgs, privileged/securityOpt metadata; continue `up` |
