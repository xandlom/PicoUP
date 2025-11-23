// TUN interface handler for N6 data network connectivity
// Provides user-space networking for sending/receiving IP packets to/from the data network
// Requires the TUN device to be created beforehand using scripts/setup_n6.sh

const std = @import("std");
const posix = std.posix;
const print = std.debug.print;

/// Linux TUN/TAP ioctl constants
const TUNSETIFF: u32 = 0x400454ca;
const IFF_TUN: i16 = 0x0001;
const IFF_NO_PI: i16 = 0x1000; // No packet information header

/// ifreq structure for TUN setup (simplified)
const IfReq = extern struct {
    name: [16]u8,
    flags: i16,
    _pad: [22]u8,
};

/// TUN device handler
pub const TunDevice = struct {
    fd: posix.fd_t,
    name: [16]u8,
    active: bool,

    /// Open an existing TUN device
    /// The device must be created beforehand with: sudo ip tuntap add dev <name> mode tun
    pub fn open(dev_name: []const u8) !TunDevice {
        // Open the TUN clone device
        const fd = posix.open("/dev/net/tun", .{ .ACCMODE = .RDWR }, 0) catch |err| {
            print("TUN: Failed to open /dev/net/tun: {}\n", .{err});
            print("TUN: Make sure you have permissions and the tun module is loaded\n", .{});
            return err;
        };
        errdefer posix.close(fd);

        // Set up ifreq structure
        var ifr = IfReq{
            .name = [_]u8{0} ** 16,
            .flags = IFF_TUN | IFF_NO_PI, // TUN device, no packet info header
            ._pad = [_]u8{0} ** 22,
        };

        // Copy device name (max 15 chars + null terminator)
        const copy_len = @min(dev_name.len, 15);
        @memcpy(ifr.name[0..copy_len], dev_name[0..copy_len]);

        // Attach to existing TUN device using ioctl
        const result = std.os.linux.ioctl(fd, TUNSETIFF, @intFromPtr(&ifr));
        if (result != 0) {
            print("TUN: Failed to attach to device '{s}'\n", .{dev_name});
            print("TUN: Make sure the device exists: sudo ip tuntap add dev {s} mode tun user $USER\n", .{dev_name});
            return error.TunSetupFailed;
        }

        print("TUN: Attached to device '{s}'\n", .{dev_name});

        return TunDevice{
            .fd = fd,
            .name = ifr.name,
            .active = true,
        };
    }

    /// Read a packet from the TUN device (blocking)
    /// Returns the number of bytes read, or error
    pub fn read(self: *TunDevice, buf: []u8) !usize {
        if (!self.active) return error.DeviceNotActive;
        return posix.read(self.fd, buf);
    }

    /// Write a packet to the TUN device
    /// Returns the number of bytes written, or error
    pub fn write(self: *TunDevice, data: []const u8) !usize {
        if (!self.active) return error.DeviceNotActive;
        return posix.write(self.fd, data);
    }

    /// Get the file descriptor for use with poll/select
    pub fn getFd(self: *const TunDevice) posix.fd_t {
        return self.fd;
    }

    /// Get the device name
    pub fn getName(self: *const TunDevice) []const u8 {
        // Find null terminator
        for (self.name, 0..) |c, i| {
            if (c == 0) return self.name[0..i];
        }
        return &self.name;
    }

    /// Close the TUN device
    pub fn close(self: *TunDevice) void {
        if (self.active) {
            posix.close(self.fd);
            self.active = false;
            print("TUN: Closed device '{s}'\n", .{self.getName()});
        }
    }

    /// Check if device is active
    pub fn isActive(self: *const TunDevice) bool {
        return self.active;
    }
};

/// Optional TUN device wrapper for graceful degradation
/// When TUN is not available, falls back to stub mode (just counting packets)
pub const OptionalTun = struct {
    device: ?TunDevice,
    stub_mode: bool,

    pub fn init(dev_name: []const u8) OptionalTun {
        const device = TunDevice.open(dev_name) catch |err| {
            print("TUN: Failed to open '{s}': {} - running in stub mode\n", .{ dev_name, err });
            print("TUN: N6 packets will be counted but not forwarded to data network\n", .{});
            print("TUN: To enable N6 forwarding, run: scripts/setup_n6.sh\n", .{});
            return OptionalTun{
                .device = null,
                .stub_mode = true,
            };
        };

        return OptionalTun{
            .device = device,
            .stub_mode = false,
        };
    }

    pub fn read(self: *OptionalTun, buf: []u8) !usize {
        if (self.device) |*dev| {
            return dev.read(buf);
        }
        return error.StubMode;
    }

    pub fn write(self: *OptionalTun, data: []const u8) !usize {
        if (self.device) |*dev| {
            return dev.write(data);
        }
        // Stub mode - pretend we wrote the data
        return data.len;
    }

    pub fn isStubMode(self: *const OptionalTun) bool {
        return self.stub_mode;
    }

    pub fn isActive(self: *const OptionalTun) bool {
        if (self.device) |*dev| {
            return dev.isActive();
        }
        return false;
    }

    pub fn close(self: *OptionalTun) void {
        if (self.device) |*dev| {
            dev.close();
        }
    }

    pub fn getFd(self: *const OptionalTun) ?posix.fd_t {
        if (self.device) |*dev| {
            return dev.getFd();
        }
        return null;
    }
};
