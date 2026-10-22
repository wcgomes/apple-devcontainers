# Change Spec: git-broker-idle-shutdown

Target domain: core. The requirements below supplement **Git credential store seeded on create paths** in [core.md](../../../core.md) and its clone cross-reference. Existing acquisition, authorization, privacy, migration, cooldown, soft-failure, and cleanup requirements remain in force. Crash supervision remains required; successful idle retirement is not a crash.

## ADDED Requirements

### Requirement: Demand-bound Git broker lifetime
The per-user credential broker MUST run for registered managed containers needing the existing HTTP(S) credential connection, including temporarily disconnected sessions and registration/control work in progress. It MUST NOT retire merely because no Git lookup occurs, no credentials are available, an explicit override awaits re-registration after a crash, or a channel is reconnecting. It MUST NOT adopt unrelated containers or broaden the existing destination/discovery scope.

The first eligible lifecycle setup MUST automatically activate the broker, without sudo or a new public command/flag, and complete the connection before HTTP(S) full clone or applicable hooks when setup succeeds. Existing setup failures MUST remain bounded, redacted, warning-only failures with the existing remediation; hook and clone failures retain their own semantics. Healthy running reuse MUST NOT duplicate the connection or acquire credentials merely to keep the broker alive. Unregister/teardown MUST NOT start a dormant broker.

After the last registration is definitively invalidated or unregistered and no admitted control/request work remains, the broker MUST retire successfully after a continuous 5-second zero-demand grace, not immediately. Registration during grace MUST cancel retirement. Idle eligibility MUST be reconsidered at intervals no greater than 2 seconds when runtime probes and control handling are responsive. Under healthy, promptly responding local adapters, retirement MUST complete no later than 7 seconds after demand reaches zero; external stop/removal MUST be observed within 2 seconds and retirement complete within 9 seconds of that event. These are internal timing constants, not public configuration. Outstanding work MUST retain its existing finite deadlines; unregistered work MUST be fenced/cancelled rather than extend lifetime indefinitely. No provider polling or credential acquisition is permitted for reconciliation, activation, or idle detection.

#### Scenario: I01 - first eligible container prepares before consumers
- Given no running broker and a managed container with discovered HTTP(S) destinations
- When fresh up, clone, rebuild replacement, real start, up start-stopped, or running up/start repair prepares its connection
- Then one broker is automatically activated and a successful setup connects before full HTTP(S) clone or applicable hooks, without a new public command/flag
- And no-source/SSH-only skips do not activate it, and an actual setup failure retains the existing soft-failure behavior

#### Scenario: I02 - last unregister retires but another session keeps service alive
- Given two registered managed containers and no in-progress request
- When one unregisters and later the last unregisters
- Then the first removal leaves the remaining session usable, and the last removal starts the grace and retires the broker successfully between 5 and 7 seconds later under healthy local conditions
- And teardown against a dormant broker does not activate it

#### Scenario: I03 - registered inactivity and reconnect are not idle
- Given a registered running container, including a disconnected channel in bounded backoff, a provider miss, or a crash-recovered explicit-override registration awaiting re-registration
- When more than 7 seconds elapse without a successful Git lookup
- Then the service does not retire for idleness, does not poll credentials, and preserves authorization/override fencing and existing recovery behavior

#### Scenario: I04 - rapid stop/start cancels grace
- Given the last session was removed and the broker is inside its 5-second grace
- When an eligible lifecycle setup registers a running container
- Then retirement is cancelled, setup connects before its consumers, and a later last-session removal starts a new full grace

### Requirement: Revalidated and race-safe broker retirement
Before idle retirement the broker MUST revalidate outstanding registered demand against authoritative runtime state and serialize the final no-demand decision with registration admission. A successful registration MUST never be acknowledged by an instance already committed to idle retirement. A registration that loses the retirement race MUST retry activation/IPC within its existing setup deadline, without creating a second registry owner or falsely reporting successful setup. Cleanup of an old instance MUST NOT delete a successor's endpoint or restore an obsolete registration/generation.

Definitively stopped, removed, unmanaged, or identity-replaced registered containers MUST lose their usable sessions and pending replies within bounded reconciliation. A failed/timeout/unparseable/ambiguous runtime observation MUST NOT be treated as proof of absence or allow idle shutdown of potentially active registered demand. Such registrations MUST remain nonsecret recovery intent until definitive revalidation or explicit unregister; unvalidated identity MUST NOT be used to deliver credentials or establish a new channel. A transient runtime outage alone MUST NOT cancel an already admitted valid request or replay it. Existing request deadlines and explicit invalidation fencing still apply. When authoritative state becomes available again, recovery or invalidation MUST resume automatically. Only registered managed-container identities are candidates; name reuse MUST NOT inherit the old session.

#### Scenario: I05 - external runtime stop or removal
- Given the last registered managed container and healthy, promptly responding runtime probes
- When it is stopped or removed outside adevcontainer
- Then its session and pending replies are invalidated within 2 seconds, and the process retires after the 5-second grace and no later than 9 seconds after the event without provider polling

#### Scenario: I06 - runtime uncertainty preserves demand safely
- Given a registered container and an admitted request
- When runtime observation temporarily fails, times out, or returns invalid/ambiguous output
- Then the observation does not remove the registration, cancel that request solely for that reason, start idle retirement, authorize an unvalidated replacement, or replay a request
- And existing request deadlines remain in force; later valid observation reconnects the same identity or invalidates a definitively stopped/absent/replaced identity and permits a fresh idle grace

#### Scenario: I07 - registration versus final shutdown boundary
- Given an empty broker whose grace has expired
- When registration races its final recheck and retirement commitment, including runtime-validation callbacks completing out of order
- Then registration either cancels retirement and connects on that owner, or retries against an activated successor within the existing deadline; it is never acknowledged and then discarded by idle shutdown
- And only one owner exists, late old-generation results cannot remove a newer session, and old cleanup cannot unlink the successor socket

### Requirement: Idle exit without permanent launchd restart
The existing per-user launchd supervision MUST distinguish successful idle retirement from failure. Successful idle exit MUST leave no running broker and MUST NOT schedule an automatic restart loop. A subsequent eligible lifecycle setup MUST start a loaded-but-dormant job as well as an absent job without killing a healthy owner. A crash while registered demand exists MUST still restart automatically, reconcile saved nonsecret identities, and recover channels without another host executable or invoking lifecycle command; existing explicit-override and stale-generation fences remain in force.

A login/bootstrap with no eligible saved sessions MAY start a bounded reconciliation process but MUST settle to no running broker after the zero-demand grace and MUST remain dormant without new demand. Saved stale registrations MUST be revalidated rather than keeping the process permanently alive once authoritative runtime state proves they are inactive. Existing installed unconditional-restart definitions MUST be replaced on the next eligible activation without requiring manual service repair; existing healthy registration intent MUST survive this update. No new daemon or public lifecycle command is permitted.

Definition migration MUST be safely resumable after failure or interruption. Matching on-disk target bytes alone MUST NOT be treated as proof that the loaded definition was updated, and an ensure attempt MUST NOT report success while leaving the obsolete loaded definition in place. Confirmed healthy reuse MUST NOT reload the job on every registration.

#### Scenario: I08 - clean idle exit stays dormant and later activates
- Given the last session is gone and the service exits successfully for idleness
- When more than two configured launchd throttle intervals pass without new demand and then a new eligible setup occurs
- Then no automatic restart was observed in that interval, and the setup starts the loaded dormant job and connects normally without duplicate ownership

#### Scenario: I09 - crash with active sessions recovers
- Given saved nonsecret registrations for running managed containers and a supervised broker
- When the process crashes or is killed abnormally
- Then launchd automatically starts a replacement, which revalidates identities and reconnects eligible channels without a lifecycle invocation or provider polling
- And pending old requests fail within their deadlines, stale generations are rejected, and explicit overrides still require private re-registration

#### Scenario: I10 - login and stale registrations settle to dormant
- Given an installed job at login/bootstrap and either an empty registry or saved registrations authoritatively shown to be inactive
- When startup reconciliation completes
- Then no session is invented, zero-demand grace leads to successful retirement within the healthy-runtime timing bounds, and no repeated idle restarts occur

#### Scenario: I11 - upgrade unconditional supervision safely
- Given an existing installed unconditional-restart definition and nonsecret registration intent
- When the next eligible setup ensures the service
- Then the definition is updated automatically, valid session intent is retained, setup reconnects within its deadline, and subsequent idle exit stays dormant while crash recovery remains enabled
- And a failed or interrupted migration resumes safely on the next eligible attempt without falsely accepting an obsolete loaded definition or repeatedly replacing a confirmed healthy job
