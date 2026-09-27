/// Realtime client for live quiz battles: the protocol v1 codec, the connection manager with
/// leases, backoff, heartbeat, clock sync and resume, typed server events, and the pure match
/// reducer. See docs/protocol.md for the wire contract.
library;

export 'src/channel_tracker.dart' show ChannelTracker, ResumeEntry, SeqDecision;
export 'src/config.dart' show RealtimeConfig;
export 'src/conn_state.dart';
export 'src/connection.dart'
    show Ack, RealtimeConnection, RealtimeLease, RealtimeLogger, ReplyMatcher, TicketFetcher;
export 'src/envelope.dart'
    show Envelope, MessageIds, encodeClientMessage, maxMessageIdLength, protocolVersion;
export 'src/errors.dart' show RealtimeError, RealtimeErrorCode;
export 'src/events.dart';
export 'src/match_state.dart'
    show
        EmoteState,
        MatchEnd,
        MatchPlayer,
        MatchState,
        MyAnswer,
        Rematch,
        reduceMatch,
        selectAnswer;
export 'src/realtime_clock.dart' show RealtimeClock, SystemRealtimeClock;
export 'src/server_clock.dart' show ClockSample, ServerClock;
export 'src/socket.dart' show RealtimeSocket, WebSocketConnector;
export 'src/web_socket_channel_connector.dart' show WebSocketChannelConnector;
