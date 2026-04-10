#include "common/args.h"
#include "uvent/Uvent.h"
#include "uvent/tasks/AwaitableFrame.h"
#include "uvent/system/SystemContext.h"
#include "uvent/net/Socket.h"

using namespace usub::uvent;

static constexpr size_t MAX_READ = 64*1024;
static const uint8_t RESP[] =
  "HTTP/1.1 200 OK\r\n"
  "Content-Type: application/json\r\n"
  "Content-Length: 20\r\n"
  "Connection: keep-alive\r\n"
  "\r\n"
  "{\"status\":\"success\"}";

task::Awaitable<void> clientCoro(net::TCPClientSocket s) {
    utils::DynamicBuffer buf; buf.reserve(MAX_READ);
    for(;;){
        buf.clear();
        ssize_t r = co_await s.async_read(buf, MAX_READ);
        if (r <= 0) { s.shutdown(); break; }
        size_t off = 0, len = sizeof(RESP)-1;
        while (off < len) {
            ssize_t w = co_await s.async_write(const_cast<uint8_t*>(RESP+off), len-off);
            if (w <= 0) { s.shutdown(); co_return; }
            off += size_t(w);
        }
    }
    co_return;
}

task::Awaitable<void> acceptLoop(std::string host, uint16_t port) {
    net::TCPServerSocket srv{host, int(port)};
    for (;;) co_await srv.async_accept(clientCoro);
}

int main(int argc, char** argv){
    auto a = parse_args(argc, argv);
    usub::Uvent rt(a.threads);
    rt.for_each_thread([&](int threadIndex, thread::ThreadLocalStorage* tls)
		    { system::co_spawn_static(acceptLoop(a.host, a.port), threadIndex); });
    rt.run();
    return 0;
}
