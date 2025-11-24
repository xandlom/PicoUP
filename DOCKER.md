# Docker Compose Guide for PicoUP

This guide explains how to run PicoUP using Docker Compose for easy testing and development.

## Prerequisites

- Docker Engine 20.10 or later
- Docker Compose v2.0 or later
- Linux host (for TUN device support)

## Quick Start

### 1. Build the containers

```bash
docker-compose build
```

This builds the PicoUP image with Zig 0.14.1 and all dependencies.

### 2. Start UPF and Echo Server

```bash
docker-compose up upf echo-server
```

This starts:
- **UPF**: Listening on ports 8805 (PFCP) and 2152 (GTP-U)
- **Echo Server**: UDP echo server on port 9999

The UPF automatically creates and configures the TUN device (upf0) for N6 interface.

### 3. Run the N3 Client Test

In a separate terminal:

```bash
docker-compose run --rm n3-client
```

This runs the N3 client which:
1. Establishes PFCP association with UPF
2. Creates a PFCP session with PDRs and FARs
3. Sends GTP-U encapsulated UDP packets
4. Receives echoed responses
5. Cleans up the session

## Architecture

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│   n3-client     │─────►│      upf        │─────►│  echo-server    │
│ (gNodeB + UE)   │ GTP-U│  (port 2152)    │ N6   │   (port 9999)   │
│                 │◄─────│  (port 8805)    │◄─────│                 │
└─────────────────┘ PFCP └─────────────────┘      └─────────────────┘
                            TUN device (upf0)
```

## Services

### upf
The main User Plane Function. Requires:
- `NET_ADMIN` capability for TUN device creation
- `/dev/net/tun` device access
- Host network mode for simplicity

**Ports:**
- 8805/udp: PFCP control plane
- 2152/udp: GTP-U data plane

### echo-server
UDP echo server simulating an application on the N6 (data network) side.

**Port:** 9999/udp

### tcp-echo-server (profile: tcp)
TCP echo server for testing TCP traffic through the UPF.

**Port:** 9998/tcp

### n3-client (profile: client)
Simulates a gNodeB + UE, sends test traffic through GTP-U tunnel.

Runs once and exits after completing the test.

### tcp-n3-client (profile: tcp-client)
TCP variant of the N3 client for testing TCP traffic.

## Common Usage Patterns

### Basic UDP Test

```bash
# Terminal 1: Start infrastructure
docker-compose up upf echo-server

# Terminal 2: Run test
docker-compose run --rm n3-client
```

### TCP Test

```bash
# Terminal 1: Start infrastructure with TCP profile
docker-compose --profile tcp up upf tcp-echo-server

# Terminal 2: Run TCP test
docker-compose run --rm tcp-n3-client
```

### Run UPF Only

```bash
docker-compose up upf
```

### View Logs

```bash
# Follow all logs
docker-compose logs -f

# Follow specific service
docker-compose logs -f upf

# View last 100 lines
docker-compose logs --tail=100 upf
```

### Stop All Services

```bash
docker-compose down
```

### Rebuild After Code Changes

```bash
docker-compose build
docker-compose up upf echo-server
```

## Profiles

Docker Compose profiles allow you to selectively start services:

- **Default**: upf, echo-server
- **tcp**: tcp-echo-server
- **client**: n3-client (manual run only)
- **tcp-client**: tcp-n3-client (manual run only)

### Using Profiles

```bash
# Start with TCP profile
docker-compose --profile tcp up

# Start multiple profiles
docker-compose --profile tcp --profile client up
```

## Development Workflow

### 1. Make code changes

Edit source files in your local directory.

### 2. Rebuild the container

```bash
docker-compose build upf
```

### 3. Restart services

```bash
docker-compose up upf echo-server
```

### 4. Test changes

```bash
docker-compose run --rm n3-client
```

## Troubleshooting

### TUN Device Errors

**Problem:** Error creating TUN device

**Solution:** Ensure Docker has access to `/dev/net/tun`:
```bash
# Check if device exists on host
ls -l /dev/net/tun

# If missing, load the module
sudo modprobe tun
```

### NET_ADMIN Capability

**Problem:** "Missing NET_ADMIN capability" error

**Solution:** The docker-compose.yml already includes `cap_add: NET_ADMIN`. If running with `docker run`, add:
```bash
docker run --cap-add=NET_ADMIN --device=/dev/net/tun ...
```

### Port Already in Use

**Problem:** "Address already in use" for port 8805 or 2152

**Solution:**
```bash
# Check what's using the port
sudo lsof -i :8805
sudo lsof -i :2152

# Stop the conflicting service or use different ports
```

### Container Exits Immediately

**Problem:** UPF container exits right after starting

**Solution:** Check logs for errors:
```bash
docker-compose logs upf
```

Common issues:
- Missing TUN device support on host
- Insufficient privileges
- Build errors

## Advanced Configuration

### Custom External Interface

The entrypoint script auto-detects the external interface for NAT. To override:

Edit `docker-compose.yml`:
```yaml
services:
  upf:
    environment:
      - EXTERNAL_IF=eth1
```

### Multiple UPF Instances

To run multiple UPF instances, modify `docker-compose.yml` to use different ports:

```yaml
services:
  upf1:
    ports:
      - "8805:8805/udp"
      - "2152:2152/udp"

  upf2:
    ports:
      - "8806:8805/udp"
      - "2153:2152/udp"
```

### Volume Mounts for Development

The docker-compose.yml already mounts the source directory:
```yaml
volumes:
  - .:/app
```

This allows you to rebuild inside the container:
```bash
docker-compose exec upf zig build
```

## Network Mode

Currently using **host network mode** for simplicity. This means:
- Containers share the host's network namespace
- UPF can directly create TUN devices
- Port conflicts can occur with host services

### Alternative: Bridge Network

For production or isolation, consider bridge networking:
```yaml
services:
  upf:
    networks:
      - upf-network

networks:
  upf-network:
    driver: bridge
```

Note: Bridge mode requires additional configuration for TUN device access.

## Production Considerations

This Docker setup is designed for development and testing. For production:

1. **Remove volume mounts**: Build the image with code baked in
2. **Use specific image tags**: Version your Docker images
3. **Add health checks**: Monitor UPF health
4. **Resource limits**: Set CPU/memory limits
5. **Logging**: Configure proper log aggregation
6. **Security**: Review capabilities and privileges

Example production docker-compose.yml additions:
```yaml
services:
  upf:
    deploy:
      resources:
        limits:
          cpus: '2'
          memory: 2G
    healthcheck:
      test: ["CMD", "nc", "-zu", "localhost", "8805"]
      interval: 30s
      timeout: 10s
      retries: 3
    restart: always
```

## References

- [Main README](README.md) - General PicoUP documentation
- [CLAUDE.md](CLAUDE.md) - Development guide
- [Docker Documentation](https://docs.docker.com/)
- [Docker Compose Documentation](https://docs.docker.com/compose/)
