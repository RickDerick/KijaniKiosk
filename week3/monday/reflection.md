# Reflection

## Question 1: /proc boundary

`/proc` is a virtual filesystem (procfs) that the Linux kernel creates in memory and mounts at boot.

The contents do not persist after a reboot because they were never stored anywhere. They are a live view of the kernel's memory. When the system shuts down, the kernel and everything it was tracking are gone. On the next boot, procfs is mounted fresh and starts describing a new set of processes with new PIDs.

This tells me that the process data in my investigation was a point-in-time snapshot, not a record. Each `ps` output showed the system only at the instant I ran it, and it can change between one command and the next.

## Question 2: Kernel space and process isolation

A runaway user-space process cannot corrupt kernel memory because the CPU and the kernel keep the two apart. Every process runs in its own virtual address space, and the kernel's memory is mapped as accessible only in kernel mode. The CPU hardware enforces this through privilege levels (ring 3 for user space, ring 0 for the kernel) and the memory management unit (MMU), which checks every memory access against the page tables. If a user process tries to touch kernel memory, the CPU raises a fault and the kernel kills the process with a segmentation fault instead of letting the access happen. The only legitimate way into the kernel is through system calls, where the kernel validates the request.

This is why the Python memory consumer (PID 7924) could only fill its own address space. Even though it ran as root, the worst it could do was use up RAM until the OOM killer stepped in. If the boundary did not exist, any buggy or malicious program could overwrite kernel data, crash the whole system or take full control of it, and one bad process could corrupt every other process on the machine.

## Question 3: The triage pipeline you built

The most complex pipeline I ran was:

```bash
grep -E "ERROR|WARN|CRITICAL" /var/log/kijanikiosk/app.log | awk '{print $4}' | sort | uniq -c | sort -rn
```

1. `grep -E "ERROR|WARN|CRITICAL"` reads app.log and outputs only the lines containing one of those log levels.
2. `awk '{print $4}'` takes those lines and outputs only the fourth field, which is the first word of the error message (Query, ECONNREFUSED, Database, and so on).
3. `sort` puts those words in alphabetical order so identical words sit next to each other.
4. `uniq -c` collapses each group of adjacent identical words into one line with a count in front.
5. `sort -rn` sorts those counted lines numerically in reverse, so the most frequent error appears first.

If I reversed `sort` and `uniq -c`, the counts would be wrong. `uniq` only merges duplicates that are next to each other, so on unsorted input the same word would appear several times with small, split-up counts. If I reversed `grep` and `awk`, awk would first reduce every line to its fourth field, which no longer contains the log level, so grep would match nothing and the pipeline would output nothing.

## Question 4: Containers and the kernel

A Docker container would appear in my `ps aux` output because a container is not a separate machine. It is a group of ordinary Linux processes running on the same kernel as the host. The kernel isolates them using namespaces: a PID namespace gives the container its own process numbering (its main process sees itself as PID 1), and other namespaces give it its own network, mounts and hostname. Cgroups limit how much CPU and memory the container can use.

The host can see the container's processes because namespaces are one-way. The container sees only what is inside its namespace, but the host runs in the parent namespace and sees everything, with the container's processes listed under their real host PIDs. So a container provides process-level isolation, not hardware-level isolation. Unlike a virtual machine, it shares the host kernel, which makes it lighter and faster, but it also means a kernel vulnerability can affect every container on the host.

## Question 5: Operational consequence

Based on the log evidence, the failure cascade looks like this:

1. **Around 04:07:55**, the API lost its connection to its backend, most likely MySQL. The logs show Database, Connection and ECONNREFUSED errors, meaning the connection attempts were actively refused.
2. **Queries started failing**, which shows up as the Query errors. Any API request that needed the database could not complete.
3. **The application started retrying.** The 06:22:18, 06:22:23 and 06:22:28 errors are exactly 5 seconds apart, which matches an automated retry loop. Each request waited through these retries instead of failing fast.
4. **Requests piled up.** While requests sat waiting on retries, response times grew, which is the latency users saw. Held requests and pending work also consume memory, which fits the Memory warning in the log.
5. **The API stopped serving.** By the time of my investigation, `/api/health` returned 404 and no application port was listening, so the degradation had progressed from slow responses to the API not being served at all.

The memory pressure was a result of this chain, not the start of it. The root cause was the loss of database connectivity, and the retry behaviour turned a failed dependency into a slow and eventually unavailable API.
