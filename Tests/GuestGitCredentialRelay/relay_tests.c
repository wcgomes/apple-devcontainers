/* Synthetic credentials only. Exercises the executable, including the shipped ELF on Linux. */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum { HEADER = 32, LIMIT = 65536 };
static const char *binary;
typedef struct { pid_t pid; int in, out; } Child;
static Child spawn_output(const char *mode, const char *dir, const char *operation, int *keep) {
    int in[2], out[2]; assert(pipe(in) == 0 && pipe(out) == 0);
    assert(fcntl(in[0], F_SETFD, FD_CLOEXEC) == 0 && fcntl(in[1], F_SETFD, FD_CLOEXEC) == 0);
    assert(fcntl(out[0], F_SETFD, FD_CLOEXEC) == 0 && fcntl(out[1], F_SETFD, FD_CLOEXEC) == 0);
    pid_t pid = fork(); assert(pid >= 0);
    if (!pid) {
        assert(dup2(in[0], 0) >= 0 && dup2(out[1], 1) >= 0);
        close(in[0]); close(in[1]); close(out[0]); close(out[1]);
        execl(binary, binary, mode, dir, operation, (char *)NULL);
        _exit(127);
    }
    close(in[0]); if (keep) *keep = out[1]; else close(out[1]);
    return (Child){pid, in[1], out[0]};
}
static Child spawn(const char *mode, const char *dir, const char *operation) { return spawn_output(mode, dir, operation, NULL); }
static double monotonic(void) { struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0); return t.tv_sec + t.tv_nsec / 1e9; }
static void write_all(int fd, const void *data, size_t count) {
    const unsigned char *p = data;
    while (count) { ssize_t n = write(fd, p, count); if (n < 0) perror("synthetic harness write"); assert(n > 0); p += n; count -= (size_t)n; }
}
static void read_all(int fd, void *data, size_t count) {
    unsigned char *p = data;
    while (count) {
        struct pollfd pollfd = {fd, POLLIN, 0}; assert(poll(&pollfd, 1, 3000) > 0);
        ssize_t n = read(fd, p, count); assert(n > 0); p += n; count -= (size_t)n;
    }
}
static uint32_t u32(const unsigned char *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static size_t frame(int fd, unsigned char *data) {
    read_all(fd, data, HEADER);
    assert(memcmp(data, "AGCR\0\1", 6) == 0);
    size_t length = u32(data + 24); assert(length <= LIMIT - HEADER);
    read_all(fd, data + HEADER, length); return HEADER + length;
}
static int finish(Child child) {
    close(child.in); close(child.out);
    int status; assert(waitpid(child.pid, &status, 0) == child.pid);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}
static void hello(Child relay) {
    unsigned char data[LIMIT]; size_t size = frame(relay.out, data);
    assert(data[7] == 1 && data[23] == 7);
    /* A version/platform checked acknowledgement is required before listening. */
    write_all(relay.in, data, size);
}
static Child query(const char *dir, const char *op, const char *input) {
    Child child = spawn("client", dir, op);
    size_t offset = 0, count = strlen(input);
    while (offset < count) {
        ssize_t written = write(child.in, input + offset, count - offset);
        if (written < 0 && errno == EPIPE) break; /* Bounded parser may reject oversized input early. */
        assert(written > 0); offset += (size_t)written;
    }
    close(child.in); child.in = -1;
    return child;
}
static void empty(Child child, int success) {
    unsigned char byte; struct pollfd p = {child.out, POLLIN, 0};
    assert(poll(&p, 1, 3000) > 0 && read(child.out, &byte, 1) == 0);
    assert((finish(child) == 0) == success);
}
static void answer(Child child, const char *expected) {
    char output[256] = {0}; size_t count = strlen(expected);
    assert(count < sizeof(output)); read_all(child.out, output, count);
    assert(!memcmp(output, expected, count)); empty(child, 1);
}
static size_t field(unsigned char *p, unsigned key, const char *value) {
    size_t len = strlen(value); assert(len < 256);
    p[0] = 0; p[1] = (unsigned char)key; p[2] = 0; p[3] = (unsigned char)len;
    memcpy(p + 4, value, len); return len + 4;
}
static void wait_socket(const char *dir) {
    char path[256]; snprintf(path, sizeof(path), "%s/credential.sock", dir);
    for (int i = 0; i < 300; i++) {
        struct stat st; if (lstat(path, &st) == 0 && S_ISSOCK(st.st_mode)) return;
        (void)poll(NULL, 0, 10);
    }
    assert(!"relay socket not created");
}
static void malformed_client(const char *dir, unsigned char *frame_data, size_t size) {
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
    assert(snprintf(address.sun_path, sizeof(address.sun_path), "%s/credential.sock", dir) < (int)sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); assert(fd >= 0);
    assert(connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0);
    write_all(fd, frame_data, size);
    assert(shutdown(fd, SHUT_WR) == 0);
    struct pollfd p = {fd, POLLIN, 0}; assert(poll(&p, 1, 3000) > 0);
    unsigned char byte; assert(read(fd, &byte, 1) == 0); close(fd);
}
int main(int argc, char **argv) {
    assert(argc == 2); binary = argv[1]; signal(SIGPIPE, SIG_IGN); alarm(90);
    const char *tmp = getenv("TMPDIR"); if (!tmp) tmp = "/tmp";
    char dir[256]; assert(snprintf(dir, sizeof(dir), "%s/adev-relay-XXXXXX", tmp) < (int)sizeof(dir));
    assert(mkdtemp(dir)); assert(chmod(dir, 0700) == 0);
    /* This is the initial behavioral red: absent executable cannot return a valid hello. */
    Child relay = spawn("relay", dir, "7"); hello(relay); wait_socket(dir);
    const char *input = "protocol=https\nhost=example.invalid:8443\npath=org/répô@x:y\nusername=u@:/é\n\n";
    Child a = query(dir, "get", input), b = query(dir, "get", input);
    unsigned char first[LIMIT], second[LIMIT]; size_t n1 = frame(relay.out, first), n2 = frame(relay.out, second);
    assert(first[7] == 2 && second[7] == 2 && memcmp(first + 8, second + 8, 8) != 0);
    assert(n1 == n2 && memcmp(first + HEADER, second + HEADER, n1 - HEADER) == 0);
    /* Replies are intentionally inverted and fragmented; empty answer means a safe miss. */
    second[7] = 4; memset(second + 24, 0, 4);
    write_all(relay.in, second, 9); write_all(relay.in, second + 9, HEADER - 9);
    first[7] = 4; memset(first + 24, 0, 4); write_all(relay.in, first, HEADER);
    empty(a, 1); empty(b, 1);
    Child roundtrip = query(dir, "get", input); (void)frame(relay.out, first);
    unsigned char fixture[256]; size_t fixture_size = 0;
    fixture_size += field(fixture + fixture_size, 1, "https");
    fixture_size += field(fixture + fixture_size, 2, "example.invalid:8443");
    fixture_size += field(fixture + fixture_size, 3, "org/répô@x:y");
    fixture_size += field(fixture + fixture_size, 4, "u@:/é");
    assert(u32(first + 24) == fixture_size && !memcmp(first + HEADER, fixture, fixture_size));
    first[7] = 4;
    size_t payload = field(first + HEADER, 4, "u@:/é");
    payload += field(first + HEADER + payload, 5, "synthetic@:/é");
    memset(first + 24, 0, 4); first[27] = (unsigned char)payload;
    write_all(relay.in, first, HEADER + payload);
    answer(roundtrip, "username=u@:/é\npassword=synthetic@:/é\n\n");
    unsigned char invalid[256] = {0}; memcpy(invalid, "AGCR\0\1\0\2", 8);
    invalid[25] = 1; /* 65536-byte payload exceeds the full-frame bound. */
    malformed_client(dir, invalid, HEADER);
    invalid[25] = 0; invalid[27] = 10;
    (void)field(invalid + HEADER, 4, "x"); (void)field(invalid + HEADER + 5, 4, "y");
    malformed_client(dir, invalid, HEADER + 10);
    invalid[27] = 5; invalid[HEADER + 4] = '\n'; malformed_client(dir, invalid, HEADER + 5);
    invalid[HEADER + 4] = 0; malformed_client(dir, invalid, HEADER + 5);
    invalid[HEADER + 4] = 0xff; malformed_client(dir, invalid, HEADER + 5);
    invalid[HEADER + 4] = 'x'; invalid[15] = 1; malformed_client(dir, invalid, HEADER + 5);
    invalid[15] = 0; malformed_client(dir, invalid, HEADER - 1);
    /* Store never crosses the channel, even if no relay exists. */
    empty(query(dir, "store", "username=synthetic\npassword=synthetic\n\n"), 1);
    struct pollfd p = {relay.out, POLLIN, 0}; assert(poll(&p, 1, 30) == 0);
    Child erased = query(dir, "erase", input);
    size_t ne = frame(relay.out, first); assert(ne > HEADER && first[7] == 3);
    first[7] = 4; memset(first + 24, 0, 4); write_all(relay.in, first, HEADER); empty(erased, 1);
    /* Backpressure must not extend the 15s deadline or modify the caller's OFD.
     * Retain the shared stdout writer and leave only one page of pipe capacity. */
    int shared; Child blocked = spawn_output("client", dir, "get", &shared);
    int original_flags = fcntl(shared, F_GETFL); assert(original_flags >= 0);
    assert(fcntl(shared, F_SETFL, original_flags | O_NONBLOCK) == 0);
    unsigned char fill[4096]; memset(fill, 'x', sizeof(fill));
    while (write(shared, fill, sizeof(fill)) > 0) {}
    assert(errno == EAGAIN); assert(read(blocked.out, fill, sizeof(fill)) == (ssize_t)sizeof(fill));
    assert(fcntl(shared, F_SETFL, original_flags) == 0);
    double start = monotonic(); write_all(blocked.in, input, strlen(input)); close(blocked.in); blocked.in = -1;
    (void)frame(relay.out, first); first[7] = 4;
    payload = field(first + HEADER, 4, "synthetic");
    first[HEADER + payload] = 0; first[HEADER + payload + 1] = 5;
    first[HEADER + payload + 2] = (unsigned char)(60000 >> 8); first[HEADER + payload + 3] = (unsigned char)60000;
    memset(first + HEADER + payload + 4, 'x', 60000); payload += 60004;
    for (unsigned i = 0; i < 4; i++) first[24 + i] = (unsigned char)(payload >> ((3 - i) * 8));
    write_all(relay.in, first, HEADER + payload);
    int status = 0, exited = 0, unchanged = 1;
    while (monotonic() - start < 16) {
        int observed = fcntl(shared, F_GETFL);
        /* Darwin may expose kernel pipe bookkeeping bits after a large write;
         * compare the caller-controlled POSIX status flags, not those bits. */
        if ((observed & (O_NONBLOCK | O_APPEND | O_SYNC)) != (original_flags & (O_NONBLOCK | O_APPEND | O_SYNC))) unchanged = 0;
        if (waitpid(blocked.pid, &status, WNOHANG) == blocked.pid) { exited = 1; break; }
        (void)poll(NULL, 0, 10);
    }
    if (!exited) { kill(blocked.pid, SIGKILL); assert(waitpid(blocked.pid, &status, 0) == blocked.pid); }
    close(shared); close(blocked.out);
    int backpressure_ok = exited && WIFEXITED(status) && WEXITSTATUS(status) != 0 && unchanged;
    if (!backpressure_ok) fprintf(stderr, "backpressure exited=%d status=%d unchanged=%d elapsed=%.3f\n", exited, status, unchanged, monotonic() - start);
    Child saturated[64]; unsigned char requests[64][HEADER];
    for (int i = 0; i < 64; i++) saturated[i] = query(dir, "get", input);
    for (int i = 0; i < 64; i++) { (void)frame(relay.out, first); memcpy(requests[i], first, HEADER); }
    empty(query(dir, "get", input), 0);
    for (int i = 63; i >= 0; i--) { requests[i][7] = 4; memset(requests[i] + 24, 0, 4); write_all(relay.in, requests[i], HEADER); }
    for (int i = 0; i < 64; i++) empty(saturated[i], 1);
#ifdef __linux__
    /* A closed waiter must not leave POLLHUP spinning until its 15s deadline. */
    int disconnected = socket(AF_UNIX, SOCK_STREAM, 0); assert(disconnected >= 0);
    struct sockaddr_un endpoint = {0}; endpoint.sun_family = AF_UNIX;
    assert(snprintf(endpoint.sun_path, sizeof(endpoint.sun_path), "%s/credential.sock", dir) < (int)sizeof(endpoint.sun_path));
    assert(connect(disconnected, (struct sockaddr *)&endpoint, sizeof(endpoint)) == 0);
    unsigned char request[256] = {0}; memcpy(request, "AGCR\0\1\0\2", 8);
    size_t request_payload = field(request + HEADER, 1, "https"); request_payload += field(request + HEADER + request_payload, 2, "example.invalid");
    request[27] = (unsigned char)request_payload; write_all(disconnected, request, HEADER + request_payload);
    (void)frame(relay.out, first); close(disconnected);
    clockid_t child_clock; assert(clock_getcpuclockid(relay.pid, &child_clock) == 0);
    struct timespec before, after; assert(clock_gettime(child_clock, &before) == 0);
    (void)poll(NULL, 0, 300); assert(clock_gettime(child_clock, &after) == 0);
    assert((after.tv_sec - before.tv_sec) + (after.tv_nsec - before.tv_nsec) / 1e9 < 0.1);
#endif
    /* Duplicate/conflicting fields, malformed records, and bounded inputs fail closed locally. */
    empty(query(dir, "get", "protocol=https\nprotocol=http\nhost=x\n\n"), 0);
    empty(query(dir, "get", "protocol=https\nhost=x\nbroken\n\n"), 0);
    char *large = malloc(LIMIT + 100); assert(large); memset(large, 'x', LIMIT + 99); large[LIMIT + 99] = 0;
    empty(query(dir, "get", large), 0); free(large);
    /* A stale generation cannot satisfy a current waiter. EOF then releases that waiter. */
    Child pending = query(dir, "get", input); (void)frame(relay.out, first);
    first[7] = 4; first[23] = 6; memset(first + 24, 0, 4); write_all(relay.in, first, HEADER);
    p = (struct pollfd){pending.out, POLLIN, 0}; assert(poll(&p, 1, 30) == 0);
    close(relay.in); relay.in = -1; empty(pending, 0); assert(finish(relay) == 0);
    char socket_path[256]; snprintf(socket_path, sizeof(socket_path), "%s/credential.sock", dir);
    assert(access(socket_path, F_OK) == -1);
    /* Never unlink a regular file or symlink, or use a public/foreign directory. */
    int file = open(socket_path, O_CREAT | O_WRONLY, 0600); assert(file >= 0); close(file);
    relay = spawn("relay", dir, "7"); hello(relay); empty(relay, 0); assert(access(socket_path, F_OK) == 0);
    assert(unlink(socket_path) == 0 && symlink("untouched", socket_path) == 0);
    relay = spawn("relay", dir, "7"); hello(relay); empty(relay, 0);
    struct stat st; assert(lstat(socket_path, &st) == 0 && S_ISLNK(st.st_mode)); assert(unlink(socket_path) == 0);
    assert(chmod(dir, 0755) == 0); empty(spawn("relay", dir, "7"), 0);
    assert(chmod(dir, 0700) == 0);
    /* Ancestor symlinks are also rejected. */
    char link[280]; snprintf(link, sizeof(link), "%s-link", dir); assert(symlink(dir, link) == 0);
    empty(spawn("relay", link, "7"), 0); assert(unlink(link) == 0);
    /* A real stale owned socket is replaced, but a second relay cannot steal a live one. */
    int stale = socket(AF_UNIX, SOCK_STREAM, 0); assert(stale >= 0);
    struct sockaddr_un address = {0}; address.sun_family = AF_UNIX;
    assert(strlen(socket_path) < sizeof(address.sun_path)); strcpy(address.sun_path, socket_path);
    assert(bind(stale, (struct sockaddr *)&address, sizeof(address)) == 0); close(stale);
    assert(chmod(socket_path, 0600) == 0);
    relay = spawn("relay", dir, "7"); hello(relay); wait_socket(dir);
    empty(spawn("relay", dir, "7"), 0);
    /* Deadlines are exercised with the shipped 15s default, not a test-only product switch. */
    Child timed = query(dir, "get", input); (void)frame(relay.out, first);
    struct pollfd timeout = {timed.out, POLLIN, 0}; assert(poll(&timeout, 1, 18000) > 0); empty(timed, 0);
    close(relay.in); relay.in = -1; assert(finish(relay) == 0);
    char lock[280]; snprintf(lock, sizeof(lock), "%s/relay.lock", dir); assert(unlink(lock) == 0);
    assert(rmdir(dir) == 0); assert(backpressure_ok); puts("PASS native relay executable tests");
    return 0;
}
