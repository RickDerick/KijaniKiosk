# KijaniKiosk API Server - Triage Report
**Date:** 2026-09-27
**Investigated by:** Derick Haron Alukwe
**Server:** derickharon (localhost)
**Incident start (approximate):** 2024-01-15 04:07:55

## Summary
The host itself is healthy. CPU load is low, there are no stuck (D) or zombie (Z) processes, the disk is only 10% full, 9.7 GiB of memory is available with no swap in use, and syslog shows no OOM kills or I/O errors. The latency appears to come from the application layer. The app log shows repeated database and connection failures (ECONNREFUSED, Query, Database, Retry), and the API health endpoint returns 404 even though the web server on port 80 answers normally. A root-owned Python process holding ~512 MB of RAM was also found and is not part of the application.

## Process and Resource State
- **CPU:** No saturation. The top consumers are desktop processes: Chrome renderers (PID 7606 at 6.7%, PID 6488 at 5.6%), gnome-shell (PID 4864 at 5.1%) and the Chrome GPU process (PID 6172 at 3.6%). mysqld (PID 2191) uses only 1.2% CPU.
- **Memory:** No memory pressure. `free -h` shows 14 GiB total, 4.8 GiB used, 6.3 GiB free, 4.7 GiB buff/cache and **9.7 GiB available**. Swap is 4.0 GiB with **0 B used**, so the system has not needed to page anything out. The two largest consumers are mysqld (PID 2191, 3.4% / ~516 MB RSS) and an unexpected process: `python3 -c` (PID 7924, user **root**, started 01:32, 3.4% / ~512 MB RSS). Its script allocates 500 × 1 MB strings and then sleeps for 3600 seconds. It is a deliberate memory consumer with no relation to the KijaniKiosk service.
- **D-state:** `ps aux | awk '$8 ~ /^D/'` returned nothing. One kernel worker (`kworker/u60:0+i915_flip`, PID 7998) appeared briefly in D< state in the CPU snapshot. This is a transient Intel GPU page-flip and not a concern.
- **Zombies:** None found.
- **Uptime:** mysqld and the system services started at 01:06, which matches the systemd-oomd start entry in syslog at 2026-09-27 01:06:45. That was the most recent boot.

## Filesystem and Disk
- `/` (/dev/nvme0n1p6): 406G total, 39G used, **10%**. There is no disk pressure.
- `/boot/efi`: 96M total, 86M used, **90%**. This is unrelated to the incident but worth cleaning up old kernel/EFI entries before it fills up.
- `/tmp` and `/dev/shm` (tmpfs): 1% used.
- **/var/log/kijanikiosk is 271M**, which makes it the largest directory in /var/log, bigger than the systemd journal (224M). That is disproportionate for a log that contains only 9 ERROR/WARN/CRITICAL lines. Either there is heavy INFO/DEBUG logging, or there are large unrotated or unexpected files in that directory.

## Log Analysis
- **App log (/var/log/kijanikiosk/app.log):** 6 ERROR lines and 9 ERROR/WARN/CRITICAL lines in total, grouped into two clusters:
  - 2024-01-15 04:07:55 to 04:08:01: 3 errors within 6 seconds
  - 2024-01-15 06:22:18, 06:22:23, 06:22:28: 3 errors exactly 5 seconds apart, which looks like an automated retry loop
- **Error categories** (by message keyword): Query ×2, ECONNREFUSED ×2, Database ×2, Retry ×1, Memory ×1, Connection ×1. The pattern points to the application failing to reach a backend dependency (most likely MySQL), with queries failing and retries firing.
- **Syslog:** There are no "killed process", I/O error or disk-quota entries. The "OOM killer disabled/enabled" kernel messages (2026-09-26 13:56:36, 2026-09-27 00:44:04) are the normal suspend/resume sequence, not memory-pressure kills. The Chrome service_worker errors are unrelated.
- **Note:** The app log timestamps (2024-01-15) do not match the system clock (2026-09-27). The app may log with a different clock, or this log may be historical or seeded. The exact incident time should be confirmed.

## Network and Service State
- **Listening ports:** 80 on all interfaces (backlog 511); MySQL on 127.0.0.1:3306 and X-protocol 127.0.0.1:33060 (localhost only, as expected); CUPS on 631; systemd-resolved on 53. **No application port (3000/8080) and no 443/HTTPS listener** was found. The Process column was empty because `ss` was run without sudo.
- **HTTP checks:** `http://localhost/` returned **200 in 2.3 ms**. `http://localhost/api/health` returned **404 in 1.5 ms**. The web server is fast and up, but the API route is not being served, so either the API process is down or the proxy/route is missing.
- **TCP state:** 16 TCP sockets in total. `ss -tan` showed 7 LISTEN, 5 ESTAB, 2 TIME-WAIT and 1 CLOSE-WAIT, with 0 orphaned. There is no connection backlog or exhaustion. The single CLOSE-WAIT means a local process has not closed a socket after the peer did. It is minor, but it should be identified.

## Assessment
The latency is most likely caused by the API failing to connect to its backend, not by host resource exhaustion. The ECONNREFUSED, Database, Query and Retry entries show the application repeatedly failing to reach a dependency (most likely MySQL) and retrying at 5-second intervals. Requests that wait on those retries would show up to users as high latency. The 404 on /api/health, together with the absence of any application port listener, suggests the API is now not being served at all. The 5-second retry spacing matches the 5-second gaps in the error log.

The root-owned Python memory consumer (PID 7924) is a secondary anomaly. It holds ~512 MB, about 10% of the 4.8 GiB in use, but with 9.7 GiB still available and no swap activity it is not causing memory pressure and cannot by itself explain the latency. It is unauthorised, though, and could explain the "Memory" warning in the app log. Confidence in the database/API hypothesis is moderate, because the full log messages and the API process status have not been reviewed yet.

## Recommended Next Steps
1. **Restore and verify the API service.** Run `sudo ss -tlnp` to see process names, check the API's service status (systemd/pm2/supervisor), and review the web server config for the /api route. The goal is for /api/health to return 200.
2. **Confirm the database connectivity failure.** Read the full log lines around both clusters (`grep -B3 -A3 "ERROR" /var/log/kijanikiosk/app.log`), check `/var/log/mysql/error.log` for restarts or refused connections at those times, and test the app's DB credentials against 127.0.0.1:3306.
3. **Remove the rogue memory consumer and audit the log directory.** Trace PID 7924's origin (`ps -o ppid= -p 7924`, `sudo ls -l /proc/7924/cwd`), then kill it. Run `du -ah /var/log/kijanikiosk | sort -rh | head` to find what is inflating that directory, and confirm logrotate covers it.
