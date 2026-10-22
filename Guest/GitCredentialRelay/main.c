/* adevcontainer private credential transport, protocol 1.
 * All integers are big endian. Header: AGCR, u16 version, u16 operation,
 * u64 request, u64 generation, u32 payload size, u32 reserved (zero).
 * Payload: repeated u16 field, u16 byte length, UTF-8 value; unique fields
 * 1 protocol, 2 host, 3 path, 4 username, 5 password, 6 platform.
 * Operations: 1 hello/ack, 2 get, 3 erase, 4 reply (empty = miss).
 * The host supplies generation and must echo the hello before serving clients.
 */
#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
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

enum { HEADER = 32, LIMIT = 65536, CLIENTS = 64, DEADLINE = 15000 };
#if defined(__aarch64__) || defined(__arm64__)
#define PLATFORM "linux/arm64"
#elif defined(__x86_64__)
#define PLATFORM "linux/amd64"
#else
#error Unsupported guest architecture
#endif
typedef struct { unsigned char bytes[LIMIT]; size_t size, offset; } Buffer;
typedef struct { int fd; uint64_t id; int64_t deadline; Buffer input, output; int waiting; } Client;
static volatile sig_atomic_t stopped;
static void stop_signal(int sig) { (void)sig; stopped = 1; }
static int64_t now_ms(void) {
    struct timespec t; if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static void wipe(void *data, size_t count) {
    volatile unsigned char *p = data; while (count--) *p++ = 0;
}
static uint64_t integer(const unsigned char *p, size_t size) {
    uint64_t value = 0; while (size--) value = value << 8 | *p++; return value;
}
static void put(unsigned char *p, uint64_t value, size_t size) {
    while (size) { p[--size] = (unsigned char)value; value >>= 8; }
}
static void header(Buffer *b, int op, uint64_t id, uint64_t generation, size_t payload) {
    memset(b->bytes, 0, HEADER); memcpy(b->bytes, "AGCR", 4);
    put(b->bytes + 4, 1, 2); put(b->bytes + 6, (uint64_t)op, 2);
    put(b->bytes + 8, id, 8); put(b->bytes + 16, generation, 8);
    put(b->bytes + 24, payload, 4); b->size = HEADER + payload; b->offset = 0;
}
static int utf8(const unsigned char *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char c = p[i++];
        if (c < 0x20 || c == 0x7f) return 0;
        if (c < 0x80) continue;
        unsigned need; uint32_t value, min;
        if (c >= 0xc2 && c <= 0xdf) { need = 1; value = c & 31; min = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { need = 2; value = c & 15; min = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { need = 3; value = c & 7; min = 0x10000; }
        else return 0;
        if (need > n - i) return 0;
        while (need--) { c = p[i++]; if ((c & 0xc0) != 0x80) return 0; value = value << 6 | (c & 63); }
        if (value < min || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return 0;
    }
    return 1;
}
static int fields(const unsigned char *p, size_t size, int hello) {
    unsigned seen = 0;
    while (size) {
        if (size < 4) return 0;
        unsigned key = (unsigned)integer(p, 2), len = (unsigned)integer(p + 2, 2);
        if (!key || key > 6 || (seen & (1u << key)) || len > size - 4) return 0;
        if ((hello && key != 6) || (!hello && key == 6) || !utf8(p + 4, len)) return 0;
        seen |= 1u << key; p += 4 + len; size -= 4 + len;
    }
    return !hello || seen == (1u << 6);
}
/* -1 invalid, 0 partial, otherwise total size. */
static int frame_size(const Buffer *b) {
    if (b->size < HEADER) return 0;
    if (memcmp(b->bytes, "AGCR\0\1", 6) || integer(b->bytes + 28, 4)) return -1;
    uint64_t length = integer(b->bytes + 24, 4), op = integer(b->bytes + 6, 2);
    if (length > LIMIT - HEADER || op < 1 || op > 4) return -1;
    if (b->size < HEADER + length) return 0;
    if (!fields(b->bytes + HEADER, (size_t)length, op == 1)) return -1;
    return (int)(HEADER + length);
}
static int nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL); return flags < 0 ? -1 : fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}
static int ready(int fd, short events, int64_t deadline) {
    while (!stopped) {
        int64_t left = deadline - now_ms(); if (left <= 0) return 0;
        struct pollfd p = {fd, events, 0}; int n = poll(&p, 1, left > INT_MAX ? INT_MAX : (int)left);
        if (n > 0) return !(p.revents & (POLLERR | POLLNVAL)) && (p.revents & (events | POLLHUP));
        if (n < 0 && errno != EINTR) return 0;
    }
    return 0;
}
static int transfer(int fd, unsigned char *data, size_t count, int writing, int64_t deadline) {
    while (count && ready(fd, writing ? POLLOUT : POLLIN, deadline)) {
        ssize_t n = writing ? write(fd, data, count) : read(fd, data, count);
        if (n > 0) { data += n; count -= (size_t)n; }
        else if (!n || (errno != EAGAIN && errno != EINTR)) return 0;
    }
    return !count;
}
static int credential_output(unsigned char *data, size_t count, int64_t deadline) {
#ifndef __APPLE__
    /* A Linux proc-fd reopen creates a new open file description for a pipe.
     * dup/fcntl would change Git's shared stdout flags, even after fork. Never
     * reopen regular files: doing so would change their shared file offset. */
    struct stat original, reopened;
    if (!fstat(1, &original) && S_ISFIFO(original.st_mode)) {
        int fd = open("/proc/self/fd/1", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd >= 0) {
            int ok = !fstat(fd, &reopened) && reopened.st_dev == original.st_dev && reopened.st_ino == original.st_ino
                && transfer(fd, data, count, 1, deadline);
            close(fd); return ok;
        }
    }
#endif
    /* macOS's /dev/fd is only dup, and procfs need not exist in a Linux guest.
     * Contain potentially blocking output in one bounded/reaped writer without
     * touching the caller's OFD. Its own alarm also bounds orphan lifetime if
     * the supervisor is killed with an unhandleable signal. No exec/env/argv. */
    if (now_ms() >= deadline) return 0;
    pid_t writer = fork(); if (writer < 0) return 0;
    if (!writer) {
        signal(SIGALRM, SIG_DFL);
        int64_t remaining = deadline - now_ms(); if (remaining <= 0) _exit(1);
        alarm((unsigned)((remaining + 999) / 1000));
        _exit(transfer(1, data, count, 1, deadline) ? 0 : 1);
    }
    int status = 0;
    while (!stopped && now_ms() < deadline) {
        pid_t result = waitpid(writer, &status, WNOHANG);
        if (result == writer) return WIFEXITED(status) && WEXITSTATUS(status) == 0;
        if (result < 0 && errno != EINTR) return 0;
        (void)poll(NULL, 0, 5);
    }
    kill(writer, SIGKILL); while (waitpid(writer, &status, 0) < 0 && errno == EINTR) {}
    return 0;
}
static int receive(int fd, Buffer *b, int64_t deadline) {
    b->size = HEADER; b->offset = 0;
    if (!transfer(fd, b->bytes, HEADER, 0, deadline)) return 0;
    uint64_t length = integer(b->bytes + 24, 4); if (length > LIMIT - HEADER) return 0;
    if (!transfer(fd, b->bytes + HEADER, (size_t)length, 0, deadline)) return 0;
    b->size += (size_t)length; return frame_size(b) == (int)b->size;
}
/* Walk each component without following symlinks. Only the final, user-owned
 * directory must be 0700; ancestors such as /private/tmp are not ours to change. */
static int private_dir(const char *path) {
    if (path[0] != '/' || strlen(path) >= PATH_MAX) return -1;
    char copy[PATH_MAX]; strcpy(copy, path); int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return -1;
    char *save = NULL, *component = strtok_r(copy, "/", &save);
    if (!component) { close(fd); return -1; }
    while (component) {
        if (!strcmp(component, ".") || !strcmp(component, "..")) { close(fd); return -1; }
        int next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); if (next < 0) return -1; fd = next; component = strtok_r(NULL, "/", &save);
    }
    struct stat st;
    if (fstat(fd, &st) || st.st_uid != geteuid() || (st.st_mode & 0777) != 0700) { close(fd); return -1; }
    return fd;
}
static int endpoint(const char *dir, struct sockaddr_un *address) {
    memset(address, 0, sizeof(*address)); address->sun_family = AF_UNIX;
    int n = snprintf(address->sun_path, sizeof(address->sun_path), "%s/credential.sock", dir);
    return n > 0 && (size_t)n < sizeof(address->sun_path);
}
static int owned_socket(int dirfd, struct stat *st) {
    return !fstatat(dirfd, "credential.sock", st, AT_SYMLINK_NOFOLLOW) && S_ISSOCK(st->st_mode)
        && st->st_uid == geteuid() && !(st->st_mode & 0077);
}
static int peer(int fd) {
#ifdef __APPLE__
    uid_t uid; gid_t gid; return !getpeereid(fd, &uid, &gid) && uid == geteuid();
#else
    struct { pid_t pid; uid_t uid; gid_t gid; } credentials;
    socklen_t size = sizeof(credentials);
    return !getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) && credentials.uid == geteuid();
#endif
}
static int git_input(Buffer *b, int op, int64_t deadline) {
    Buffer text = {0}; int complete = 0;
    while (text.size < LIMIT && ready(0, POLLIN, deadline)) {
        ssize_t n = read(0, text.bytes + text.size, LIMIT - text.size);
        if (!n) { complete = 1; break; }
        if (n < 0) { if (errno == EINTR || errno == EAGAIN) continue; break; }
        text.size += (size_t)n;
        if ((text.size >= 2 && !memcmp(text.bytes + text.size - 2, "\n\n", 2)) || (text.size == 1 && text.bytes[0] == '\n')) { complete = 1; break; }
    }
    int ok = complete && text.size < LIMIT; size_t offset = HEADER, start = 0; unsigned seen = 0;
    for (size_t i = 0; ok && i < text.size; i++) {
        if (text.bytes[i] != '\n') continue;
        size_t len = i - start; if (!len) { if (i + 1 != text.size) ok = 0; break; }
        unsigned char *line = text.bytes + start, *equal = memchr(line, '=', len);
        if (!equal || !utf8(line, len)) { ok = 0; break; }
        size_t keysize = (size_t)(equal - line), value = len - keysize - 1; unsigned key = 0;
        const char *keys[] = {"", "protocol", "host", "path", "username", "password"};
        for (unsigned k = 1; k <= 5; k++) if (strlen(keys[k]) == keysize && !memcmp(line, keys[k], keysize)) key = k;
        if (key) {
            if ((seen & (1u << key)) || offset + 4 + value > LIMIT || value > UINT16_MAX) { ok = 0; break; }
            seen |= 1u << key; put(b->bytes + offset, key, 2); put(b->bytes + offset + 2, value, 2);
            memcpy(b->bytes + offset + 4, equal + 1, value); offset += 4 + value;
        }
        start = i + 1;
    }
    if (start < text.size && text.bytes[text.size - 1] != '\n') ok = 0;
    wipe(&text, sizeof(text)); if (!ok) return 0;
    header(b, op, 0, 0, offset - HEADER); return 1;
}
static int client(const char *dir, const char *operation) {
    int op = !strcmp(operation, "get") ? 2 : !strcmp(operation, "erase") ? 3 : !strcmp(operation, "store") ? 0 : -1;
    if (op < 0) return 2;
    Buffer b = {0}; int64_t deadline = now_ms() + DEADLINE;
    if (!git_input(&b, op, deadline)) return 1;
    if (!op) { wipe(&b, sizeof(b)); return 0; }
    struct sockaddr_un address; int directory = private_dir(dir); struct stat st;
    if (directory < 0 || !endpoint(dir, &address) || !owned_socket(directory, &st)) { if (directory >= 0) close(directory); return 1; }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); close(directory);
    if (fd < 0) return 1;
    int ok = !nonblock(fd);
    if (ok && connect(fd, (struct sockaddr *)&address, sizeof(address)) && errno != EINPROGRESS) ok = 0;
    if (ok) ok = ready(fd, POLLOUT, deadline) && peer(fd);
    if (ok) ok = transfer(fd, b.bytes, b.size, 1, deadline) && receive(fd, &b, deadline)
        && integer(b.bytes + 6, 2) == 4 && integer(b.bytes + 8, 8) != 0 && integer(b.bytes + 16, 8) != 0;
    close(fd);
    if (ok && op == 2) {
        size_t length = 0;
        for (size_t i = HEADER; i < b.size;) {
            unsigned key = (unsigned)integer(b.bytes + i, 2), count = (unsigned)integer(b.bytes + i + 2, 2); i += 4;
            const char *name = key == 4 ? "username=" : key == 5 ? "password=" : NULL;
            if (name) {
                /* Reuse the input region only after assembling in a separate bounded buffer. */
                length += strlen(name) + count + 1;
            }
            i += count;
        }
        if (length > LIMIT - 1) ok = 0;
        else if (length) {
            Buffer output = {0};
            for (size_t i = HEADER; i < b.size;) {
                unsigned key = (unsigned)integer(b.bytes + i, 2), count = (unsigned)integer(b.bytes + i + 2, 2); i += 4;
                const char *name = key == 4 ? "username=" : key == 5 ? "password=" : NULL;
                if (name) { size_t n = strlen(name); memcpy(output.bytes + output.size, name, n); output.size += n;
                    memcpy(output.bytes + output.size, b.bytes + i, count); output.size += count; output.bytes[output.size++] = '\n'; }
                i += count;
            }
            output.bytes[output.size++] = '\n'; ok = credential_output(output.bytes, output.size, deadline); wipe(&output, sizeof(output));
        }
    }
    wipe(&b, sizeof(b)); return ok ? 0 : 1;
}
static void close_client(Client *c) {
    if (c->fd >= 0) close(c->fd); wipe(c, sizeof(*c)); c->fd = -1;
}
static int flush(int fd, Buffer *b) {
    if (b->offset == b->size) { b->offset = b->size = 0; return 1; }
    ssize_t n = write(fd, b->bytes + b->offset, b->size - b->offset);
    if (n > 0) { wipe(b->bytes + b->offset, (size_t)n); b->offset += (size_t)n; return 1; }
    return n < 0 && (errno == EAGAIN || errno == EINTR);
}
static int relay(const char *dir, const char *generation_text) {
    char *end; errno = 0; uint64_t generation = strtoull(generation_text, &end, 10);
    if (!generation || errno || *end || generation_text[0] == '-') return 2;
    struct sockaddr_un address; int directory = private_dir(dir);
    if (directory < 0 || !endpoint(dir, &address)) { if (directory >= 0) close(directory); return 1; }
    /* Hold a per-directory advisory lock for our entire lifetime, including cleanup. */
    int lock = openat(directory, "relay.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat lock_stat; struct flock lock_request = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    if (lock < 0 || fstat(lock, &lock_stat) || !S_ISREG(lock_stat.st_mode) || lock_stat.st_uid != geteuid()
        || (lock_stat.st_mode & 0777) != 0600 || lock_stat.st_nlink != 1 || fcntl(lock, F_SETLK, &lock_request)) {
        if (lock >= 0) close(lock); close(directory); return 1;
    }
    Buffer host = {0}, sending = {0}; header(&sending, 1, 0, generation, 4 + strlen(PLATFORM));
    put(sending.bytes + HEADER, 6, 2); put(sending.bytes + HEADER + 2, strlen(PLATFORM), 2);
    memcpy(sending.bytes + HEADER + 4, PLATFORM, strlen(PLATFORM));
    int64_t deadline = now_ms() + DEADLINE;
    int ok = !nonblock(0) && !nonblock(1) && transfer(1, sending.bytes, sending.size, 1, deadline)
        && receive(0, &host, deadline) && host.size == sending.size && !memcmp(host.bytes, sending.bytes, host.size);
    sending.size = sending.offset = 0; host.size = 0;
    int listener = -1, created = 0; struct stat bound = {0}, stale;
    if (ok && !fstatat(directory, "credential.sock", &stale, AT_SYMLINK_NOFOLLOW)) {
        if (!owned_socket(directory, &stale) || unlinkat(directory, "credential.sock", 0)) ok = 0;
    } else if (ok && errno != ENOENT) ok = 0;
    if (ok) {
        listener = socket(AF_UNIX, SOCK_STREAM, 0);
        if (listener < 0 || bind(listener, (struct sockaddr *)&address, sizeof(address))) ok = 0;
        else { created = 1; ok = owned_socket(directory, &bound) && !listen(listener, CLIENTS) && !nonblock(listener); }
    }
    Client *clients = calloc(CLIENTS, sizeof(Client));
    if (!clients) ok = 0; else for (int i = 0; i < CLIENTS; i++) clients[i].fd = -1;
    uint64_t next_id = 1; int result = ok ? 0 : 1;
    while (ok && !stopped) {
        struct pollfd fds[CLIENTS + 3];
        fds[0] = (struct pollfd){0, POLLIN, 0};
        fds[1] = (struct pollfd){1, sending.size ? POLLOUT : 0, 0};
        fds[2] = (struct pollfd){listener, POLLIN, 0};
        for (int i = 0; i < CLIENTS; i++) fds[i + 3] = (struct pollfd){clients[i].fd,
            clients[i].output.size ? POLLOUT : clients[i].waiting ? 0 : POLLIN, 0};
        if (poll(fds, CLIENTS + 3, 100) < 0) { if (errno == EINTR) continue; result = 1; break; }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(0, host.bytes + host.size, LIMIT - host.size);
            if (n == 0) break;
            if (n < 0 && errno != EAGAIN && errno != EINTR) { result = 1; break; }
            if (n > 0) host.size += (size_t)n;
            int size;
            while ((size = frame_size(&host)) > 0) {
                if (integer(host.bytes + 6, 2) != 4) { ok = 0; break; }
                if (integer(host.bytes + 16, 8) == generation) {
                    uint64_t id = integer(host.bytes + 8, 8);
                    for (int i = 0; i < CLIENTS; i++) if (clients[i].fd >= 0 && clients[i].waiting && clients[i].id == id && !clients[i].output.size) {
                        memcpy(clients[i].output.bytes, host.bytes, (size_t)size); clients[i].output.size = (size_t)size; break;
                    }
                }
                memmove(host.bytes, host.bytes + size, host.size - (size_t)size); host.size -= (size_t)size;
            }
            if (size < 0 || !ok) { result = 1; break; }
        }
        if (fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) { result = 1; break; }
        if (sending.size && (fds[1].revents & POLLOUT) && !flush(1, &sending)) { result = 1; break; }
        if (fds[2].revents & POLLIN) {
            int fd = accept(listener, NULL, NULL);
            if (fd >= 0) {
                int slot = -1; for (int i = 0; i < CLIENTS; i++) if (clients[i].fd < 0) { slot = i; break; }
                if (slot < 0 || !peer(fd) || nonblock(fd)) close(fd);
                else { clients[slot].fd = fd; clients[slot].deadline = now_ms() + DEADLINE; }
            }
        }
        for (int i = 0; i < CLIENTS; i++) {
            Client *c = &clients[i]; if (c->fd < 0) continue;
            if (now_ms() >= c->deadline || (fds[i + 3].revents & (POLLERR | POLLNVAL | POLLHUP))) { close_client(c); continue; }
            if (c->output.size && (fds[i + 3].revents & POLLOUT)) {
                if (!flush(c->fd, &c->output) || c->output.offset == c->output.size) close_client(c);
                continue;
            }
            if (!c->waiting && (fds[i + 3].revents & (POLLIN | POLLHUP))) {
                ssize_t n = read(c->fd, c->input.bytes + c->input.size, LIMIT - c->input.size);
                if (!n || (n < 0 && errno != EAGAIN && errno != EINTR)) { close_client(c); continue; }
                if (n > 0) c->input.size += (size_t)n;
            }
            if (!c->waiting && c->input.size) {
                int size = frame_size(&c->input);
                if (size < 0 || (size > 0 && ((size_t)size != c->input.size || integer(c->input.bytes + 8, 8)
                    || integer(c->input.bytes + 16, 8) || (integer(c->input.bytes + 6, 2) != 2 && integer(c->input.bytes + 6, 2) != 3)))) { close_client(c); continue; }
                if (size > 0 && !sending.size) {
                    if (!next_id) { ok = 0; result = 1; break; }
                    c->id = next_id++; put(c->input.bytes + 8, c->id, 8); put(c->input.bytes + 16, generation, 8);
                    memcpy(sending.bytes, c->input.bytes, (size_t)size); sending.size = (size_t)size; sending.offset = 0;
                    wipe(&c->input, sizeof(c->input)); c->waiting = 1;
                }
            }
        }
    }
    if (clients) { for (int i = 0; i < CLIENTS; i++) close_client(&clients[i]); free(clients); }
    if (listener >= 0) close(listener);
    struct stat current;
    if (created && owned_socket(directory, &current) && current.st_dev == bound.st_dev && current.st_ino == bound.st_ino)
        (void)unlinkat(directory, "credential.sock", 0);
    wipe(&host, sizeof(host)); wipe(&sending, sizeof(sending)); close(lock); close(directory); return result;
}
int main(int argc, char **argv) {
    umask(0077); signal(SIGPIPE, SIG_IGN); signal(SIGTERM, stop_signal); signal(SIGINT, stop_signal);
    if (argc == 2 && !strcmp(argv[1], "--help")) {
        puts("Private adevcontainer Git relay (protocol 1).\nUsage: relay relay PRIVATE_DIRECTORY GENERATION\n       relay client PRIVATE_DIRECTORY get|store|erase\nCredentials are accepted only on stdin; directory must be owned by the current user, mode 0700."); return 0;
    }
    if (argc != 4) { fputs("Invalid private relay invocation; use --help for the internal protocol contract.\n", stderr); return 2; }
    if (!strcmp(argv[1], "relay")) return relay(argv[2], argv[3]);
    if (!strcmp(argv[1], "client")) return client(argv[2], argv[3]);
    fputs("Unknown private relay mode; use --help.\n", stderr); return 2;
}
