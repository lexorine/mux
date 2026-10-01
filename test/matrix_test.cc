// SPDX-License-Identifier: AGPL-3.0-only
// mux.matrix against a homeserver played by a fiber of the same loop, over
// real TLS on the loopback: a certificate made for the test, trusted by the
// client and nothing else. Login, a first sync with a named room, members,
// a formatted message, a reply, an edit, a reaction and typing; a message
// sent and acknowledged; a later sync; stopped.
import std;
import splice;
import mux.config;
import mux.core;
import mux.net;
import mux.matrix;
import mux.test.certificate;
import gtest;

#include "gtest/gtest-macros.h"

namespace {

const std::string login = R"({"user_id":"@a:x.org","access_token":"tok","device_id":"DEV"})";

const std::string first_sync = R"({"next_batch":"s1","rooms":{"join":{"!r:x.org":{
 "state":{"events":[
  {"type":"m.room.create","state_key":"","event_id":"$c","sender":"@a:x.org","origin_server_ts":1,"content":{"room_version":"11"}},
  {"type":"m.room.name","state_key":"","event_id":"$n","sender":"@a:x.org","origin_server_ts":2,"content":{"name":"Garden"}},
  {"type":"m.room.member","state_key":"@b:x.org","event_id":"$mb","sender":"@b:x.org","origin_server_ts":3,"content":{"membership":"join","displayname":"B"}}]},
 "timeline":{"limited":false,"prev_batch":"p0","events":[
  {"type":"m.room.message","event_id":"$m1","sender":"@b:x.org","origin_server_ts":10,
   "content":{"msgtype":"m.text","body":"hello","format":"org.matrix.custom.html","formatted_body":"<b>hello</b>"}},
  {"type":"m.room.message","event_id":"$m2","sender":"@a:x.org","origin_server_ts":11,
   "content":{"msgtype":"m.text","body":"hi","m.relates_to":{"m.in_reply_to":{"event_id":"$m1"}}}},
  {"type":"m.room.message","event_id":"$m3","sender":"@b:x.org","origin_server_ts":12,
   "content":{"msgtype":"m.text","body":"* hello there","m.new_content":{"msgtype":"m.text","body":"hello there"},
              "m.relates_to":{"rel_type":"m.replace","event_id":"$m1"}}},
  {"type":"m.reaction","event_id":"$r1","sender":"@a:x.org","origin_server_ts":13,
   "content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$m1","key":"👍"}}}]},
 "ephemeral":{"events":[{"type":"m.typing","content":{"user_ids":["@b:x.org"]}}]},
 "unread_notifications":{"highlight_count":0,"notification_count":2}}}}})";

std::string answer(std::string_view body) {
  return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + std::to_string(body.size()) +
         "\r\n\r\n" + std::string(body);
}

struct request {
  std::string method, target, headers, body;
};

// The requests on one connection, as they come: headers to the blank
// line, then as much body as Content-Length says.
std::optional<request> take(std::string& pending) {
  const auto end = pending.find("\r\n\r\n");
  if (end == std::string::npos)
    return std::nullopt;
  const std::string head = pending.substr(0, end);
  std::size_t length = 0;
  if (const auto at = head.find("Content-Length: "); at != std::string::npos)
    length = std::stoul(head.substr(at + 16));
  if (pending.size() < end + 4 + length)
    return std::nullopt;
  request made;
  const auto first_space = head.find(' ');
  made.method = head.substr(0, first_space);
  made.target = head.substr(first_space + 1, head.find(' ', first_space + 1) - first_space - 1);
  made.headers = head;
  made.body = pending.substr(end + 4, length);
  pending.erase(0, end + 4 + length);
  return made;
}

// What the test hears from the account, and what it does back: a sink
// that knows the account it belongs to, without anything type-erased.
struct recorder;
struct sink {
  recorder* to = nullptr;
  void operator()(mux::change_t one) const;
};

struct recorder {
  mux::net::loop* running = nullptr;
  mux::model model;
  std::vector<mux::connection_t> states;
  bool sent = false;
  std::optional<mux::matrix::account<sink>> account;
};

void sink::operator()(mux::change_t one) const {
  splice::visit(splice::overloaded{[&](const mux::change::connection_changed& changed) {
                               to->states.push_back(changed.state);
                               if (splice::visit(splice::overloaded{[](const mux::connection::offline&) { return true; },
                                                              [](const mux::connection::failed&) { return true; },
                                                              [](const auto&) { return false; }},
                                              changed.state))
                                 to->running->stop();
                             },
                             [](const auto&) {}},
             one);
  // A message sent once the room is there.
  const bool room_there = splice::visit(splice::overloaded{[](const mux::change::conversation_updated&) { return true; },
                                                     [](const auto&) { return false; }},
                                     one);
  if (room_there && !to->sent) {
    to->sent = true;
    to->account->send("!r:x.org", "from mux");
  }
  to->model.apply(one);
}

// What the MSC2815 test hears from the account: removed messages fetched
// back once the room is there, refused ones kept to assert on.
struct unredact_recorder;
struct unredact_sink {
  unredact_recorder* to = nullptr;
  void operator()(mux::change_t one) const;
};

struct unredact_recorder {
  mux::net::loop* running = nullptr;
  mux::model model;
  std::vector<std::string> refused;
  bool asked = false;
  std::optional<mux::matrix::account<unredact_sink>> account;
};

void unredact_sink::operator()(mux::change_t one) const {
  splice::visit(splice::overloaded{[&](const mux::change::connection_changed& changed) {
                                if (splice::visit(splice::overloaded{[](const mux::connection::offline&) { return true; },
                                                               [](const mux::connection::failed&) { return true; },
                                                               [](const auto&) { return false; }},
                                               changed.state))
                                  to->running->stop();
                              },
                              [&](const mux::change::conversation_updated&) {
                                if (!to->asked) {
                                  to->asked = true;
                                  to->account->fetch_unredacted("!r:x.org", "$m1");
                                  to->account->fetch_unredacted("!r:x.org", "$m9");
                                }
                              },
                              [&](const mux::change::refused& refused) { to->refused.push_back(refused.what); },
                              [](const auto&) {}},
              one);
  to->model.apply(one);
  // Both answers in: the kept content shown, the erased one refused.
  const mux::account_id me{mux::protocol::matrix{}, "@a:x.org"};
  const mux::conversation* room = to->model.find({me, "!r:x.org"});
  const bool seen = room && std::ranges::any_of(room->timeline, [](const mux::message& said) {
    return said.id == "$m1" && said.unredacted.has_value();
  });
  if (seen && !to->refused.empty())
    to->account->stop();
}

TEST(Matrix, AgainstAHomeserverOverTls) {
  const auto certificate = mux::test::self_signed();
  mux::net::loop running;
  auto server_tls = mux::net::server_tls(certificate.certificate_pem, certificate.key_pem);
  auto client_tls = mux::net::client_tls();
  mux::net::trust(client_tls, certificate.certificate_pem);
  mux::net::listener listening(running);

  std::vector<request> heard;
  recorder seen{.running = &running};
  int syncs = 0;
  running.spawn([&] {
    for (;;) {
      auto socket = listening.accept();
      auto wire = std::make_shared<mux::net::stream>(running, server_tls, std::move(socket));
      running.spawn([&, wire] {
        if (!wire->accept_tls())
          return;
        std::string pending;
        for (auto it = wire->input().begin(); it != std::default_sentinel; ++it) {
          pending += *it;
          while (auto one = take(pending)) {
            heard.push_back(*one);
            std::string body = "{}";
            if (one->target.starts_with("/_matrix/client/v3/login")) {
              body = login;
            } else if (one->target.starts_with("/_matrix/client/v3/sync")) {
              ++syncs;
              if (one->target.find("since=") == std::string::npos)
                body = first_sync;
              else {
                body = R"({"next_batch":"s)" + std::to_string(syncs) + R"("})";
                if (syncs >= 3)
                  seen.account->stop();
              }
            } else if (one->target.find("/send/m.room.message/") != std::string::npos) {
              body = R"({"event_id":"$sent"})";
            }
            wire->write(answer(body));
            wire->flush();
          }
        }
      });
    }
  });

  mux::matrix::settings how{.user_id = "@a:x.org",
                            .password = "pw",
                            .homeserver = "https://127.0.0.1:" + std::to_string(listening.port()),
                            .sync_timeout = std::chrono::milliseconds(0)};
  seen.account.emplace(running, client_tls, how, sink{&seen});
  seen.account->start();
  running.run();
  const auto& states = seen.states;
  const auto& model = seen.model;

  EXPECT_EQ(states.front(), mux::connection_t{mux::connection::connecting{}});
  EXPECT_NE(std::find(states.begin(), states.end(), mux::connection_t{mux::connection::online{}}), states.end());
  EXPECT_EQ(states.back(), mux::connection_t{mux::connection::offline{}});

  const mux::account_id me{mux::protocol::matrix{}, "@a:x.org"};
  const mux::conversation* room = model.find({me, "!r:x.org"});
  ASSERT_NE(room, nullptr);
  EXPECT_EQ(room->name, "Garden");
  EXPECT_EQ(room->unread, 2);
  EXPECT_EQ(room->typing, (std::vector<std::string>{"@b:x.org"}));
  ASSERT_GE(room->timeline.size(), 3u);
  // The message, edited in place; its HTML; the reaction on it.
  EXPECT_EQ(room->timeline[0].id, "$m1");
  EXPECT_EQ(room->timeline[0].body.plain, "hello there");
  EXPECT_TRUE(room->timeline[0].edited);
  EXPECT_EQ(room->timeline[0].reactions.at("👍"), (std::set<std::string>{"@a:x.org"}));
  // The reply, and what it replies to.
  EXPECT_EQ(room->timeline[1].id, "$m2");
  EXPECT_EQ(room->timeline[1].replies_to, "$m1");
  EXPECT_TRUE(room->timeline[1].outgoing);
  // Sent from here: known by its event id once the server answered.
  const auto sent_one = std::find_if(room->timeline.begin(), room->timeline.end(),
                                     [](const mux::message& one) { return one.body.plain == "from mux"; });
  ASSERT_NE(sent_one, room->timeline.end());
  EXPECT_EQ(sent_one->id, "$sent");
  EXPECT_EQ(sent_one->delivery, mux::delivery_t{mux::delivery::sent{}});

  // What the client asked: login without a token, sync with one, the
  // message PUT with a transaction id -- one of this run's own, "mux-<when
  // the run began>-<n>", never the "mux1" every run used to start from: a
  // server answers a repeated id with the event it made the first time.
  ASSERT_FALSE(heard.empty());
  EXPECT_TRUE(heard.front().target.starts_with("/_matrix/client/v3/login"));
  EXPECT_NE(heard.front().body.find("m.login.password"), std::string::npos);
  EXPECT_NE(heard.front().body.find("\"user\":\"a\""), std::string::npos) << heard.front().body;
  bool bearer = false, put = false;
  for (const auto& one : heard) {
    if (one.target.starts_with("/_matrix/client/v3/sync"))
      bearer = bearer || one.headers.find("Authorization: Bearer tok") != std::string::npos;
    if (const auto at = one.target.find("/send/m.room.message/mux-");
        one.method == "PUT" && at != std::string::npos &&
        one.target.find("/send/m.room.message/mux1") == std::string::npos)
      put = true;
  }
  EXPECT_TRUE(bearer);
  EXPECT_TRUE(put);
}

// MSC2815: a room's moderator viewing a removed message's content. The
// first sync brings a message removed before it arrived; fetched back with
// the MSC's parameter, the server answers with what it kept, and the model
// shows it where the message was. A message the server already erased is
// refused with why.
TEST(Matrix, ModeratorViewsRemovedContent) {
  const std::string removed_sync = R"({"next_batch":"s1","rooms":{"join":{"!r:x.org":{
   "state":{"events":[
    {"type":"m.room.create","state_key":"","event_id":"$c","sender":"@a:x.org","origin_server_ts":1,"content":{"room_version":"11"}},
    {"type":"m.room.name","state_key":"","event_id":"$n","sender":"@a:x.org","origin_server_ts":2,"content":{"name":"Garden"}},
    {"type":"m.room.power_levels","state_key":"","event_id":"$pl","sender":"@a:x.org","origin_server_ts":3,
     "content":{"users":{"@a:x.org":100},"redact":50}}]},
   "timeline":{"limited":false,"prev_batch":"p0","events":[
    {"type":"m.room.message","event_id":"$m1","sender":"@b:x.org","origin_server_ts":10,
     "content":{},"unsigned":{"redacted_because":{"type":"m.room.redaction","event_id":"$red1","sender":"@a:x.org",
      "origin_server_ts":11,"content":{}}}}]}}}}})";
  const std::string kept_content = R"({"type":"m.room.message","event_id":"$m1","sender":"@b:x.org","origin_server_ts":10,
   "content":{"msgtype":"m.text","body":"it was never about the cake"}})";
  const std::string erased = R"({"errcode":"FI.MAU.MSC2815_UNREDACTED_CONTENT_DELETED",
   "error":"The content for that event has already been erased from the database"})";

  const auto certificate = mux::test::self_signed();
  mux::net::loop running;
  auto server_tls = mux::net::server_tls(certificate.certificate_pem, certificate.key_pem);
  auto client_tls = mux::net::client_tls();
  mux::net::trust(client_tls, certificate.certificate_pem);
  mux::net::listener listening(running);

  std::vector<request> heard;
  unredact_recorder seen{.running = &running};
  int syncs = 0;
  running.spawn([&] {
    for (;;) {
      auto socket = listening.accept();
      auto wire = std::make_shared<mux::net::stream>(running, server_tls, std::move(socket));
      running.spawn([&, wire] {
        if (!wire->accept_tls())
          return;
        std::string pending;
        for (auto it = wire->input().begin(); it != std::default_sentinel; ++it) {
          pending += *it;
          while (auto one = take(pending)) {
            heard.push_back(*one);
            if (one->target.starts_with("/_matrix/client/v3/login")) {
              wire->write(answer(login));
            } else if (one->target.starts_with("/_matrix/client/v3/sync")) {
              ++syncs;
              if (one->target.find("since=") == std::string::npos)
                wire->write(answer(removed_sync));
              else {
                wire->write(answer(R"({"next_batch":"s)" + std::to_string(syncs) + R"("})"));
                if (syncs >= 12)
                  seen.account->stop();
              }
            } else if (one->target.find("/event/") != std::string::npos) {
              if (one->target.find("m9") != std::string::npos) {
                wire->write("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: " +
                            std::to_string(erased.size()) + "\r\n\r\n" + erased);
              } else {
                wire->write(answer(kept_content));
              }
            } else {
              wire->write(answer("{}"));
            }
            wire->flush();
          }
        }
      });
    }
  });

  mux::matrix::settings how{.user_id = "@a:x.org",
                            .password = "pw",
                            .homeserver = "https://127.0.0.1:" + std::to_string(listening.port()),
                            .sync_timeout = std::chrono::milliseconds(0)};
  seen.account.emplace(running, client_tls, how, unredact_sink{&seen});
  seen.account->start();
  running.run();

  // Asked with the MSC's unstable parameter, both times.
  int unredacted_asks = 0;
  for (const auto& one : heard)
    if (one.target.find("/event/") != std::string::npos) {
      EXPECT_NE(one.target.find("fi.mau.msc2815.include_unredacted_content=true"), std::string::npos) << one.target;
      ++unredacted_asks;
    }
  EXPECT_EQ(unredacted_asks, 2);

  const mux::account_id me{mux::protocol::matrix{}, "@a:x.org"};
  const mux::conversation* room = seen.model.find({me, "!r:x.org"});
  ASSERT_NE(room, nullptr);
  EXPECT_EQ(room->name, "Garden");
  // The removed message put back where its time puts it, as removed, with
  // what the server kept.
  ASSERT_EQ(room->timeline.size(), 1u);
  EXPECT_EQ(room->timeline[0].id, "$m1");
  EXPECT_EQ(room->timeline[0].sender, "@b:x.org");
  EXPECT_TRUE(room->timeline[0].redacted);
  ASSERT_TRUE(room->timeline[0].unredacted);
  EXPECT_EQ(room->timeline[0].unredacted->plain, "it was never about the cake");
  // The erased one refused with why.
  ASSERT_EQ(seen.refused.size(), 1u);
  EXPECT_NE(seen.refused[0].find("erased"), std::string::npos) << seen.refused[0];
}

// What the dedup test hears from the account: one burst of reads and typing
// on the first room, each asked twice over, where the client used to ask
// twice.
struct dedup_recorder;
struct dedup_sink {
  dedup_recorder* to = nullptr;
  void operator()(mux::change_t one) const;
};

struct dedup_recorder {
  mux::net::loop* running = nullptr;
  bool asked = false;
  std::optional<mux::matrix::account<dedup_sink>> account;
};

void dedup_sink::operator()(mux::change_t one) const {
  splice::visit(splice::overloaded{[&](const mux::change::connection_changed& changed) {
                                if (splice::visit(splice::overloaded{[](const mux::connection::offline&) { return true; },
                                                               [](const mux::connection::failed&) { return true; },
                                                               [](const auto&) { return false; }},
                                               changed.state))
                                  to->running->stop();
                              },
                              [&](const mux::change::conversation_updated& made) {
                                if (!to->asked) {
                                  to->asked = true;
                                  to->account->mark_read(made.id.id, "$m1");
                                  to->account->mark_read(made.id.id, "$m1");
                                  to->account->typing(made.id.id, true);
                                  to->account->typing(made.id.id, true);
                                  to->account->typing(made.id.id, false);
                                }
                              },
                              [](const auto&) {}},
              one);
}

// A receipt asked twice goes out once, and typing said twice goes out once
// until it changes: the fake homeserver counts what it hears.
TEST(Matrix, SendsEachReceiptAndTypingOnce) {
  const auto certificate = mux::test::self_signed();
  mux::net::loop running;
  auto server_tls = mux::net::server_tls(certificate.certificate_pem, certificate.key_pem);
  auto client_tls = mux::net::client_tls();
  mux::net::trust(client_tls, certificate.certificate_pem);
  mux::net::listener listening(running);

  std::vector<request> heard;
  dedup_recorder seen{.running = &running};
  int syncs = 0, receipts = 0, typings = 0;
  running.spawn([&] {
    for (;;) {
      auto socket = listening.accept();
      auto wire = std::make_shared<mux::net::stream>(running, server_tls, std::move(socket));
      running.spawn([&, wire] {
        if (!wire->accept_tls())
          return;
        std::string pending;
        for (auto it = wire->input().begin(); it != std::default_sentinel; ++it) {
          pending += *it;
          while (auto one = take(pending)) {
            heard.push_back(*one);
            if (one->target.find("/receipt/") != std::string::npos)
              ++receipts;
            else if (one->target.find("/typing/") != std::string::npos)
              ++typings;
            std::string body = "{}";
            if (one->target.starts_with("/_matrix/client/v3/login")) {
              body = login;
            } else if (one->target.starts_with("/_matrix/client/v3/sync")) {
              ++syncs;
              if (one->target.find("since=") == std::string::npos)
                body = first_sync;
              else
                body = R"({"next_batch":"s)" + std::to_string(syncs) + R"("})";
            }
            wire->write(answer(body));
            wire->flush();
            if (receipts >= 1 && typings >= 2 && syncs >= 2)
              seen.account->stop();
            else if (syncs >= 25)
              seen.account->stop();
          }
        }
      });
    }
  });

  mux::matrix::settings how{.user_id = "@dup:x.org",
                            .password = "pw",
                            .homeserver = "https://127.0.0.1:" + std::to_string(listening.port()),
                            .sync_timeout = std::chrono::milliseconds(0)};
  seen.account.emplace(running, client_tls, how, dedup_sink{&seen});
  seen.account->start();
  running.run();

  int receipt_puts = 0, typing_puts = 0, typing_on = 0, typing_off = 0;
  for (const auto& one : heard) {
    if (one.target.find("/receipt/") != std::string::npos)
      ++receipt_puts;
    if (one.target.find("/typing/") != std::string::npos) {
      ++typing_puts;
      if (one.body.find("\"typing\":true") != std::string::npos)
        ++typing_on;
      if (one.body.find("\"typing\":false") != std::string::npos)
        ++typing_off;
    }
  }
  EXPECT_EQ(receipt_puts, 1);
  EXPECT_EQ(typing_puts, 2);
  EXPECT_EQ(typing_on, 1);
  EXPECT_EQ(typing_off, 1);
}

// What lands on disk for a room with a long timeline: only its newest
// events, the older ones left to page back to.
TEST(Matrix, KeepsOnlyRecentTimelineOnDisk) {
  std::string events;
  for (int i = 0; i < 150; ++i) {
    if (i != 0)
      events += ",";
    events += R"({"type":"m.room.message","event_id":"$e)" + std::to_string(i) + R"(","sender":"@b:x.org","origin_server_ts":)" +
              std::to_string(100 + i) + R"(,"content":{"msgtype":"m.text","body":"many"}})";
  }
  const std::string big_sync =
      R"({"next_batch":"s1","rooms":{"join":{"!r:x.org":{
   "state":{"events":[
    {"type":"m.room.create","state_key":"","event_id":"$c","sender":"@a:x.org","origin_server_ts":1,"content":{"room_version":"11"}},
    {"type":"m.room.name","state_key":"","event_id":"$n","sender":"@a:x.org","origin_server_ts":2,"content":{"name":"Garden"}}]},
   "timeline":{"limited":false,"prev_batch":"p0","events":[)" +
      events + R"(]}}}}})";

  const auto certificate = mux::test::self_signed();
  mux::net::loop running;
  auto server_tls = mux::net::server_tls(certificate.certificate_pem, certificate.key_pem);
  auto client_tls = mux::net::client_tls();
  mux::net::trust(client_tls, certificate.certificate_pem);
  mux::net::listener listening(running);

  std::vector<request> heard;
  recorder seen{.running = &running};
  int syncs = 0;
  running.spawn([&] {
    for (;;) {
      auto socket = listening.accept();
      auto wire = std::make_shared<mux::net::stream>(running, server_tls, std::move(socket));
      running.spawn([&, wire] {
        if (!wire->accept_tls())
          return;
        std::string pending;
        for (auto it = wire->input().begin(); it != std::default_sentinel; ++it) {
          pending += *it;
          while (auto one = take(pending)) {
            heard.push_back(*one);
            std::string body = "{}";
            if (one->target.starts_with("/_matrix/client/v3/login")) {
              body = login;
            } else if (one->target.starts_with("/_matrix/client/v3/sync")) {
              ++syncs;
              if (one->target.find("since=") == std::string::npos)
                body = big_sync;
              else {
                body = R"({"next_batch":"s)" + std::to_string(syncs) + R"("})";
                if (syncs >= 3)
                  seen.account->stop();
              }
            } else if (one->target.find("/send/m.room.message/") != std::string::npos) {
              body = R"({"event_id":"$sent"})";
            }
            wire->write(answer(body));
            wire->flush();
          }
        }
      });
    }
  });

  mux::matrix::settings how{.user_id = "@cap:x.org",
                            .password = "pw",
                            .homeserver = "https://127.0.0.1:" + std::to_string(listening.port()),
                            .sync_timeout = std::chrono::milliseconds(0)};
  seen.account.emplace(running, client_tls, how, sink{&seen});
  seen.account->start();
  running.run();

  const std::filesystem::path kept =
      mux::config::state_path(mux::config::file_name_of("@cap:x.org") + ".sync.json");
  std::ifstream file(kept, std::ios::binary);
  ASSERT_TRUE(static_cast<bool>(file));
  const std::string text((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
  EXPECT_NE(text.find("\"$e149\""), std::string::npos);
  EXPECT_NE(text.find("\"$e50\""), std::string::npos);
  EXPECT_EQ(text.find("\"$e49\""), std::string::npos);
  EXPECT_EQ(text.find("\"$e0\""), std::string::npos);
}

}  // namespace
