// libuv HTTP keep-alive echo server.
//
// libuv is single-loop by design, so to use N cores we run N independent
// loops in N threads, each with its own listening socket bound to the same
// port via SO_REUSEPORT (the same "one acceptor per thread" model the uvent
// and Asio servers use). With --threads 1 this degenerates to the classic
// single-loop libuv server.

#include <uv.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

static const char RESP[] =
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 20\r\n"
        "Connection: keep-alive\r\n"
        "\r\n"
        "{\"status\":\"success\"}";

struct Client {
    uv_tcp_t handle;
    uv_write_t write_req;
    bool write_in_flight = false;
    char buf[64 * 1024];
};

static void on_close(uv_handle_t *h) {
    delete reinterpret_cast<Client *>(h);
}

static void alloc_cb(uv_handle_t *h, size_t /*suggested*/, uv_buf_t *buf) {
    auto *c = reinterpret_cast<Client *>(h);
    *buf = uv_buf_init(c->buf, sizeof(c->buf));
}

static void on_write(uv_write_t *req, int status) {
    auto *c = reinterpret_cast<Client *>(req->data);
    c->write_in_flight = false;
    if (status < 0 && !uv_is_closing(reinterpret_cast<uv_handle_t *>(&c->handle)))
        uv_close(reinterpret_cast<uv_handle_t *>(&c->handle), on_close);
}

static void on_read(uv_stream_t *s, ssize_t nread, const uv_buf_t * /*buf*/) {
    auto *c = reinterpret_cast<Client *>(s);
    if (nread < 0) {
        if (!uv_is_closing(reinterpret_cast<uv_handle_t *>(s)))
            uv_close(reinterpret_cast<uv_handle_t *>(s), on_close);
        return;
    }
    if (nread == 0) return; // EAGAIN, nothing to do
    if (c->write_in_flight) return; // pipelined request while a response is still queued: wrk never does this
    uv_buf_t out = uv_buf_init(const_cast<char *>(RESP), static_cast<unsigned>(sizeof(RESP) - 1));
    c->write_req.data = c;
    c->write_in_flight = true;
    if (uv_write(&c->write_req, s, &out, 1, on_write) != 0) {
        c->write_in_flight = false;
        uv_close(reinterpret_cast<uv_handle_t *>(s), on_close);
    }
}

static void on_conn(uv_stream_t *server, int status) {
    if (status < 0) return;
    auto *c = new Client;
    uv_tcp_init(server->loop, &c->handle);
    if (uv_accept(server, reinterpret_cast<uv_stream_t *>(&c->handle)) == 0) {
        uv_tcp_nodelay(&c->handle, 1);
        uv_read_start(reinterpret_cast<uv_stream_t *>(&c->handle), alloc_cb, on_read);
    } else {
        uv_close(reinterpret_cast<uv_handle_t *>(&c->handle), on_close);
    }
}

static int run_loop(const std::string &host, int port, bool reuse_port) {
    uv_loop_t loop;
    uv_loop_init(&loop);

    uv_tcp_t srv;
    uv_tcp_init(&loop, &srv);

    sockaddr_in addr{};
    uv_ip4_addr(host.c_str(), port, &addr);

    unsigned flags = 0;
#if UV_VERSION_HEX >= 0x013100  /* UV_TCP_REUSEPORT is an enum since 1.49 */
    if (reuse_port) flags |= UV_TCP_REUSEPORT; // libuv >= 1.49
#else
    if (reuse_port) {
        std::fprintf(stderr, "libuv without UV_TCP_REUSEPORT: --threads > 1 unsupported\n");
        return 1;
    }
#endif
    int r = uv_tcp_bind(&srv, reinterpret_cast<const sockaddr *>(&addr), flags);
    if (r != 0) {
        std::fprintf(stderr, "bind error: %s\n", uv_strerror(r));
        return 1;
    }
    r = uv_listen(reinterpret_cast<uv_stream_t *>(&srv), 65535, on_conn);
    if (r != 0) {
        std::fprintf(stderr, "listen error: %s\n", uv_strerror(r));
        return 1;
    }
    return uv_run(&loop, UV_RUN_DEFAULT);
}

int main(int argc, char **argv) {
    std::string host = "0.0.0.0";
    int port = 45900;
    int threads = 1;
    for (int i = 1; i < argc; i++) {
        if (!std::strcmp(argv[i], "--port") && i + 1 < argc) port = std::atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--host") && i + 1 < argc) host = argv[++i];
        else if (!std::strcmp(argv[i], "--threads") && i + 1 < argc) threads = std::atoi(argv[++i]);
        else if (!std::strcmp(argv[i], "--reuseport")) {
            /* implied by --threads > 1 */
        }
    }
    if (threads < 1) threads = 1;

    // One loop per thread; several listeners on one port need SO_REUSEPORT.
    const bool reuse_port = threads > 1;
    std::vector<std::thread> pool;
    for (int i = 1; i < threads; i++)
        pool.emplace_back([&] { run_loop(host, port, reuse_port); });
    int rc = run_loop(host, port, reuse_port);
    for (auto &t: pool) t.join();
    return rc;
}
