#!/bin/bash
# KijaniKiosk Lab Setup - Monday Week 3
# Run as: sudo bash setup_lab.sh

apt-get update -q && apt-get install -y -q nginx curl lsof sysstat

# Create a simulated application directory
mkdir -p /opt/kijanikiosk/app /var/log/kijanikiosk

# Create an application log with simulated errors
cat > /var/log/kijanikiosk/app.log <<'EOF'
2024-01-15 03:12:04 INFO  Worker process started pid=1842
2024-01-15 03:14:22 INFO  Request processed /api/products 200 112ms
2024-01-15 03:45:10 WARN  Database connection pool at 85% capacity
2024-01-15 04:01:33 WARN  Database connection pool at 94% capacity
2024-01-15 04:07:55 ERROR Connection pool exhausted - queuing requests
2024-01-15 04:08:01 ERROR Query timeout after 30000ms: SELECT * FROM orders
2024-01-15 04:08:01 ERROR Query timeout after 30000ms: SELECT * FROM products
2024-01-15 04:09:12 WARN  Memory usage at 87% - consider restarting workers
2024-01-15 06:22:18 ERROR ECONNREFUSED database:5432 - retrying in 5s
2024-01-15 06:22:23 ERROR ECONNREFUSED database:5432 - retrying in 5s
2024-01-15 06:22:28 ERROR Retry limit reached - database connection failed
EOF

# Create a large orphaned log file (simulates log rotation failure)
dd if=/dev/urandom bs=1M count=200 2>/dev/null | base64 > /var/log/kijanikiosk/access.log.1

# Create a process that consumes memory
python3 -c "
import time
x =[]
for i in range(500):
    x.append(' ' * 1024 * 1024)
print('Memory consumer running')
time.sleep(3600)
" &

# Create a zombie process simulation (informational)
echo "Lab environment ready. PID of memory consumer: $!"
echo "Check /var/log/kijanikiosk/app.log for application errors"
echo "Check disk usage with: df -h and du -sh /var/log/*"
