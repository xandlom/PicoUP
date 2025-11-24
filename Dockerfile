# Dockerfile for PicoUP - 5G User Plane Function
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    git \
    iproute2 \
    iptables \
    iputils-ping \
    net-tools \
    kmod \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.14.1
RUN curl -L https://ziglang.org/download/0.14.1/zig-x86_64-linux-0.14.1.tar.xz -o /tmp/zig-0.14.1.tar.xz && \
    tar -xf /tmp/zig-0.14.1.tar.xz -C /opt && \
    rm /tmp/zig-0.14.1.tar.xz

# Set working directory
WORKDIR /app

# Copy source code
COPY . .

# Initialize git submodules and build
RUN /opt/zig-x86_64-linux-0.14.1/zig build -Doptimize=ReleaseFast

# Expose PFCP and GTP-U ports
EXPOSE 8805/udp 2152/udp

# Default command - run the UPF
CMD ["./zig-out/bin/picoupf"]
