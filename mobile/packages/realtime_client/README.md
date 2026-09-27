# realtime_client

The app's client for live battles over WebSocket. It implements `docs/protocol.md` (v1) in pure
Dart, with no Flutter dependency.

- **`RealtimeConnection`** manages the connection:
  - leases;
  - a fresh ticket per attempt, then `hello` and `welcome`;
  - heartbeat replies and a watchdog;
  - full-jitter backoff that pauses while offline;
  - the close-code table;
  - requests correlated with their `ack`, `error` or natural reply;
  - an answer outbox that resends with the same id;
  - resume and gap `sync`;
  - clock sync, `client.state` and takeover.
- **`ServerClock`** gives synced server time: `serverClock.nowServerMs()`.
- **`ChannelTracker`** keeps the last `seq` per `m:`/`r:` channel and builds `hello.resume`.
- **Typed events** (`ServerEvent` and its subclasses) cover every server message. Unknown types
  arrive as `UnknownEvent`.
- **`reduceMatch`** is a pure reducer from events to an immutable `MatchState`.
  `selectAnswer` adds the optimistic pick.

## Using it in the app

```dart
final rt = RealtimeConnection(
  fetchTicket: () async => (await api.post('/v1/rt/tickets'))['ticket'] as String,
  connector: WebSocketChannelConnector(Uri.parse('wss://rt.example.com/v1/ws')),
  networkAvailable: connectivity.onlineStream, // Stream<bool>
  build: 57,
  platform: 'android',
);
rt.events.listen(liveLayer.handle); // listen before acquiring: events are not buffered
rt.states.listen(banner.show);      // Idle, Ticketing, Connecting, Open, Backoff, Terminal
```

**Leases decide when the socket is open.** It opens with the first `acquire` and closes 30 s
after the last `release`, so short trips between screens reuse it.

- **Shell.** While the app is in the foreground and signed in, hold one lease
  (`rt.acquire('shell')`), so invites, inbox updates and tournament rounds arrive on every tab. A
  lease can be held indefinitely. An idle socket only answers the server's pings and re-syncs the
  clock every 5 minutes.
- **Screens.** A screen that needs the socket (Battle tab, room lobby, arena) takes its own lease
  in `initState` and releases it in `dispose`.
- **Live match.** Take a lease with `inMatch: true` for the whole match (VS screen to result).
  While it is held, reconnects back off at most 2 s, the watchdog expects the 5 s in-match
  heartbeat, and the clock re-syncs every minute.
- **Lifecycle.** Call `rt.setAppForeground(bool)` from the app lifecycle observer. Going to the
  background keeps the match lease, so the server's grace rules apply.

**Playing a match:**

```dart
var match = MatchState.initial(matchId);
rt.events.listen((e) => match = reduceMatch(match, e, me: userId));

// On tap: show the pick at once, and send it through the outbox.
match = selectAnswer(match, q: q, opt: optionId);
rt.submitAnswer(matchId, q, optionId, elapsedMs); // resent until ans.ack, never lost

// Hide the question until match.isQuestionRevealed(rt.serverClock.nowServerMs()).
// Drive the ring from match.question!.remainingMs(rt.serverClock.nowServerMs()).
```

Other requests use `request`:

```dart
final ack = await rt.request('mm.join', {...});
final ready = await rt.request('match.ready', {'match_id': id});
```

`request` completes with the `ack` or the natural reply (`mm.queued`, `mm.found` for a bot game,
`t.standings`, `rematch.status`). It fails with a `RealtimeError`, for example `BUSY` with a typed
`error.active` for "Go there", `TIMEOUT` or `DISCONNECTED`.

**Resume.**
- `mm.found`, `room.started` and `t.pairing` start tracking their match channel. After a drop,
  `hello.resume` carries every tracked channel, and replays and snapshots are applied in order.
- After a cold start, look at `rt.welcome!.active` and call `rt.syncChannel(entry.channel!)` for
  the game to reopen.
- When the result screen closes, call `rt.forgetChannel('m:$matchId')`.

**Terminal states** need a decision from the app:

| Reason | What the app does |
|---|---|
| `revoked` | Go to sign-in |
| `superseded` | Show "Playing on another device" |
| `updateRequired` | Show the update screen |
| `liveElsewhere(matchId)` | Ask "Move the game here?", then `rt.connect(takeover: true)` |

`rt.connect()` also retries at once after the user signs in again.

## Testing

```sh
cd mobile/packages/realtime_client
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

Most tests run under `fake_async`. The server side is an in-memory `FakeSocket`: two
`StreamController`s with close codes, plus a scriptable server in `test/support/harness.dart`.
`test/match_flow_test.dart` plays a whole Quick Battle through the connection and the reducer,
including a drop with replay and a restart resumed from a snapshot.
`test/web_socket_connector_test.dart` checks the real connector against a local `dart:io` server.
