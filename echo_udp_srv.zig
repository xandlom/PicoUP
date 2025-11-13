const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const time = std.time;
const Mutex = std.Thread.Mutex;

const WORKER_THREADS = 4;
const QUEUE_SIZE = 1000;

// Message structure for the work queue
const Message = struct {
    data: [1024]u8,
    length: usize,
    client_address: net.Address,
    socket: std.posix.socket_t,
};

// Thread-safe message queue
const MessageQueue = struct {
    messages: [QUEUE_SIZE]Message,
    head: Atomic(usize),
    tail: Atomic(usize),
    count: Atomic(usize),
    mutex: Mutex,

    fn init() MessageQueue {
        return MessageQueue{
            .messages = undefined,
            .head = Atomic(usize).init(0),
            .tail = Atomic(usize).init(0),
            .count = Atomic(usize).init(0),
            .mutex = Mutex{},
        };
    }

    fn enqueue(self: *MessageQueue, message: Message) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_count = self.count.load(.seq_cst);
        if (current_count >= QUEUE_SIZE) {
            return false; // Queue is full
        }

        const tail = self.tail.load(.seq_cst);
        self.messages[tail] = message;
        _ = self.tail.store((tail + 1) % QUEUE_SIZE, .seq_cst);
        _ = self.count.fetchAdd(1, .seq_cst);
        return true;
    }

    fn dequeue(self: *MessageQueue) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_count = self.count.load(.seq_cst);
        if (current_count == 0) {
            return null; // Queue is empty
        }

        const head = self.head.load(.seq_cst);
        const message = self.messages[head];
        _ = self.head.store((head + 1) % QUEUE_SIZE, .seq_cst);
        _ = self.count.fetchSub(1, .seq_cst);
        return message;
    }

    fn size(self: *MessageQueue) usize {
        return self.count.load(.seq_cst);
    }
};

// Statistics structure with atomic counters for thread safety
const Stats = struct {
    messages_received: Atomic(u64),
    messages_processed: Atomic(u64),
    messages_sent: Atomic(u64),
    messages_dropped: Atomic(u64),
    queue_size: Atomic(usize),
    start_time: i64,

    fn init() Stats {
        return Stats{
            .messages_received = Atomic(u64).init(0),
            .messages_processed = Atomic(u64).init(0),
            .messages_sent = Atomic(u64).init(0),
            .messages_dropped = Atomic(u64).init(0),
            .queue_size = Atomic(usize).init(0),
            .start_time = time.timestamp(),
        };
    }

    fn incrementReceived(self: *Stats) void {
        _ = self.messages_received.fetchAdd(1, .seq_cst);
    }

    fn incrementProcessed(self: *Stats) void {
        _ = self.messages_processed.fetchAdd(1, .seq_cst);
    }

    fn incrementSent(self: *Stats) void {
        _ = self.messages_sent.fetchAdd(1, .seq_cst);
    }

    fn incrementDropped(self: *Stats) void {
        _ = self.messages_dropped.fetchAdd(1, .seq_cst);
    }

    fn updateQueueSize(self: *Stats, size: usize) void {
        _ = self.queue_size.store(size, .seq_cst);
    }

    fn getReceived(self: *Stats) u64 {
        return self.messages_received.load(.seq_cst);
    }

    fn getProcessed(self: *Stats) u64 {
        return self.messages_processed.load(.seq_cst);
    }

    fn getSent(self: *Stats) u64 {
        return self.messages_sent.load(.seq_cst);
    }

    fn getDropped(self: *Stats) u64 {
        return self.messages_dropped.load(.seq_cst);
    }

    fn getQueueSize(self: *Stats) usize {
        return self.queue_size.load(.seq_cst);
    }
};

// Global variables
var global_stats: Stats = undefined;
var message_queue: MessageQueue = undefined;
var last_received: u64 = 0;
var last_sent: u64 = 0;
var should_stop: Atomic(bool) = Atomic(bool).init(false);

// Worker thread function
fn workerThread(thread_id: u32) void {
    print("Worker thread {} started\n", .{thread_id});

    while (!should_stop.load(.seq_cst)) {
        // Try to dequeue a message
        if (message_queue.dequeue()) |message| {
            global_stats.incrementProcessed();
            global_stats.updateQueueSize(message_queue.size());

            // Echo the message back to the client
            const bytes_sent = std.posix.sendto(
                message.socket,
                message.data[0..message.length],
                0,
                &message.client_address.any,
                message.client_address.getOsSockLen(),
            ) catch |err| {
                print("Worker {}: Error sending data: {}\n", .{ thread_id, err });
                continue;
            };

            if (bytes_sent == message.length) {
                global_stats.incrementSent();
            }

            // Optional: Print processed message info (comment out for high-traffic scenarios)
            // print("Worker {} processed message of {} bytes\n", .{ thread_id, message.length });
        } else {
            // No messages available, sleep briefly to avoid busy waiting
            time.sleep(1 * time.ns_per_ms);
        }
    }

    print("Worker thread {} stopped\n", .{thread_id});
}

// Statistics display thread function
fn statsThread() void {
    print("Statistics thread started\n", .{});

    while (!should_stop.load(.seq_cst)) {
        time.sleep(5 * time.ns_per_s); // Sleep for 5 seconds

        const current_received = global_stats.getReceived();
        const current_processed = global_stats.getProcessed();
        const current_sent = global_stats.getSent();
        const current_dropped = global_stats.getDropped();
        const current_queue_size = global_stats.getQueueSize();

        const received_rate = current_received - last_received;
        const sent_rate = current_sent - last_sent;

        const current_time = time.timestamp();
        const uptime = current_time - global_stats.start_time;

        print("\n=== UDP Echo Server Statistics (4 Threads) ===\n", .{});
        print("Uptime: {}s\n", .{uptime});
        print("Messages received: {}\n", .{current_received});
        print("Messages processed: {}\n", .{current_processed});
        print("Messages sent: {}\n", .{current_sent});
        print("Messages dropped: {}\n", .{current_dropped});
        print("Current queue size: {}\n", .{current_queue_size});
        print("Receive rate (last 5s): {} msg/s\n", .{received_rate / 5});
        print("Send rate (last 5s): {} msg/s\n", .{sent_rate / 5});
        print("Worker threads: {}\n", .{WORKER_THREADS});
        print("================================================\n", .{});

        last_received = current_received;
        last_sent = current_sent;
    }

    print("Statistics thread stopped\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Initialize global variables
    global_stats = Stats.init();
    message_queue = MessageQueue.init();

    // Create UDP socket
    const address = try net.Address.resolveIp("0.0.0.0", 8080);
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(socket);

    // Set socket to reuse address
    const enable: c_int = 1;
    try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    // Bind socket to address
    try std.posix.bind(socket, &address.any, address.getOsSockLen());

    print("UDP Echo Server started on {s}:{} with {} worker threads\n", .{ "0.0.0.0", 8080, WORKER_THREADS });
    print("Press Ctrl+C to stop the server\n", .{});

    // Start worker threads
    var worker_threads: [WORKER_THREADS]Thread = undefined;
    for (0..WORKER_THREADS) |i| {
        worker_threads[i] = try Thread.spawn(.{}, workerThread, .{@as(u32, @intCast(i))});
    }

    // Start statistics thread
    const stats_thread = try Thread.spawn(.{}, statsThread, .{});

    // Buffer for receiving messages
    var buffer: [1024]u8 = undefined;

    // Main server loop - receives messages and queues them for processing
    while (true) {
        // Receive message
        var client_address: net.Address = undefined;
        var client_address_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const bytes_received = std.posix.recvfrom(
            socket,
            &buffer,
            0,
            &client_address.any,
            &client_address_len,
        ) catch |err| {
            print("Error receiving data: {}\n", .{err});
            continue;
        };

        global_stats.incrementReceived();

        if (bytes_received == 0) {
            continue;
        }

        // Create message for the queue
        var message = Message{
            .data = undefined,
            .length = bytes_received,
            .client_address = client_address,
            .socket = socket,
        };

        // Copy the received data
        @memcpy(message.data[0..bytes_received], buffer[0..bytes_received]);

        // Try to enqueue the message
        if (!message_queue.enqueue(message)) {
            // Queue is full, drop the message
            global_stats.incrementDropped();
            print("Warning: Message queue is full, dropping message\n", .{});
        }

        global_stats.updateQueueSize(message_queue.size());
    }

    // Cleanup (this code won't be reached without signal handling)
    should_stop.store(true, .seq_cst);

    // Wait for all threads to finish
    for (worker_threads) |thread| {
        thread.join();
    }
    stats_thread.join();
}

// Test client function for testing the multi-threaded server
pub fn testClient() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    defer std.posix.close(socket);

    const server_address = try net.Address.resolveIp("127.0.0.1", 8080);

    // Send multiple test messages to test multi-threading
    for (0..10) |i| {
        var test_message: [50]u8 = undefined;
        const message = try std.fmt.bufPrint(&test_message, "Hello from client, message {}", .{i});

        // Send test message
        _ = try std.posix.sendto(
            socket,
            message,
            0,
            &server_address.any,
            server_address.getOsSockLen(),
        );

        print("Sent: {s}\n", .{message});

        // Small delay between messages
        time.sleep(100 * time.ns_per_ms);
    }

    print("All test messages sent\n", .{});
}
