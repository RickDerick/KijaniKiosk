# KijaniKiosk Access Model — Final (Week 3, Friday)

This is the Tuesday access model, updated for the Friday production foundation:
the new `health/` directory is added, and the logrotate interaction is documented.
Every decision below is enforced by `kijanikiosk-provision.sh` and verified after
a forced rotation.

## Service accounts (from audit)

| Account | UID | Primary group | Shell | Role |
|---|---|---|---|---|
| kk-api | 997 | kk-api (972) | /usr/sbin/nologin | API service |
| kk-payments | 994 | kk-payments (971) | /usr/sbin/nologin | Payments service |
| kk-logs | 993 | kk-logs (970) | /usr/sbin/nologin | Log aggregator |

Shared group `kijanikiosk` (GID 969) contains all three service accounts plus
`derickharon` and `amina`.

## Directory access table

| Path | Owner:Group | Mode | Access model | Reasoning |
|---|---|---|---|---|
| `/opt/kijanikiosk/` | root:kijanikiosk | 750 | basic | Root owns the tree; group traverses; others blocked. |
| `api/` | kk-api:kk-api | 750 | basic | Only the API account reaches its code. |
| `payments/` | kk-payments:kk-payments | 750 | basic | Isolated to payments; sensitive code. |
| `logs/` | kk-logs:kk-logs | 750 | basic | Isolated to the log account. |
| `config/` | root:kijanikiosk | dir 750, files 640 | basic + ACL | Root writes; group reads secrets; others blocked. Config lives under `/opt`, not `/etc`. |
| `shared/logs/` | kk-logs:kk-logs | 2770 | basic + ACLs | SGID unifies group ownership; ACLs give per-account access. |
| `health/` (NEW) | kk-logs:kijanikiosk | 750 | basic | Written by the provisioning health check (as kk-logs), read by the kijanikiosk group. |

## The `health/` directory (Integration Challenge B)

Phase 8 writes `/opt/kijanikiosk/health/last-provision.json`. The provisioning
script runs as root, so without explicit ownership the file would be root-owned
and unreadable to the monitoring system and to Amina without sudo.

Decision: the directory and file are owned `kk-logs:kijanikiosk`, mode `750` on
the directory and `640` on the JSON. Rationale: the log/monitoring account
(kk-logs) is the natural writer of health data, and group `kijanikiosk` gives
every legitimate reader (monitoring, Amina, the other services) read access
without sudo, while `other` gets nothing. No ACL is needed because a single
group already expresses "these readers, read-only" — this is the case where
basic group permissions are sufficient and ACLs would be over-engineering.

## The logrotate interaction (Requirement 3)

When logrotate rotates a file in `shared/logs/`, the `create 640 kk-logs
kijanikiosk` directive sets the new file's owner and mode. But standard
ownership alone would not preserve kk-api's write access or kk-payments' read
access. Those come from the **default ACLs** set on the directory:

```
default:user:kk-api:rwx
default:user:kk-payments:r-x
```

Any file created inside `shared/logs/` — including the empty replacement file
logrotate creates — inherits these default ACLs automatically. This is why the
access model survives rotation without manual intervention.

Verified after a forced rotation:

```
-rw-rw----+1 kk-api kk-logs 0 ... app.log      # note the ACL '+'
PASS: kk-api can write after logrotate
```

The `+` confirms the ACLs propagated; the PASS confirms kk-api can still write
new log entries post-rotation. Without the default ACLs, this would silently
fail and log writes would be lost after the first rotation.

## getfacl evidence

Captured in `post-remediation-verification.txt` for all four key directories
(`config`, `shared/logs`, `health`, and a rotated log file).
