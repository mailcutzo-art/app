# User flows, start to end

Every journey a student can take, step by step: what they see, what they tap, what happens
behind the scenes, and every way out. The rule for the whole app: **no dead ends and no silent
outcomes**. Every screen has a way forward and a way back. Every automatic outcome (a refund, a
cancellation, a forfeit, a prize) is explained on screen and kept in the inbox, so the student can
always find out later what happened.

References: `docs/plan.md` (features), `docs/protocol.md` (live events), `docs/api-learn.md` and
`docs/api-play.md` (REST).

---

## 0. Every app start

1. **Native splash, then the splash screen.** Two things run in parallel:
   - restoring the session (refresh token from secure storage);
   - `GET /v1/config` (`min_build`, maintenance flag, feature flags). The last good config is
     cached.
2. **Gates, in order:**
   - **Update required**, when `build < min_build`. The same screen also appears on any `426`
     response or a `4426` realtime close. It has one button, "Update on Play Store", and blocks
     everything else.
   - **Maintenance**, when the flag is set or a `503 MAINTENANCE` arrives. It shows the message
     and a Retry button. It checks again automatically every 30 s.
   - **No network:**
     - with a cached profile, the app opens Home with the offline banner and cached data;
     - without one, it opens Sign-in with "You're offline. Connect to sign in."
3. **Routing:**
   - signed out → Sign-in;
   - signed in but not onboarded → Onboarding;
   - signed in → Home.
   - **A pending destination always wins afterwards.** Examples: an invite link opened while
     signed out, or a notification tapped. The router keeps it through sign-in and onboarding, then
     opens it.
4. **Resuming live games.** If the app was killed during a live game, the device remembers the
   active game (only its kind and id, never question content). The realtime connection opens at
   once, and `welcome.active` reopens the match, lobby or tournament. If it already ended, the
   result screen opens instead.

## 1. Sign-in and onboarding (first time)

1. **Sign-in:**
   - a headline and three feature tiles (Live 1v1, Tournaments, Practice);
   - "Continue with Google";
   - "Developer login" and "Debug settings", in debug builds only.
2. Google's account picker appears, then `POST /v1/auth/google` runs.
   - **Cancel** returns to Sign-in quietly.
   - **Failures** show a message that says what to do: "That sign-in has expired. Please try
     again", "Your Google email isn't verified", or "Google sign-in is temporarily unavailable".
   - **A banned account** sees the suspension notice.
3. **Onboarding** (resumable; a step already done is skipped):
   1. **Name and username.** The username is checked live: available, taken, or not allowed.
   2. **Avatar:** a colour and a symbol.
   3. **Goal:** NEET or JEE. It decides the subjects shown everywhere and can be changed later in
      Settings.
   4. **Birth year.** Minors get safer defaults.
   5. **Notifications:** an explanation, then Android's permission prompt. This step only appears
      once push is enabled.
   - A 409 during onboarding means either "that username was just taken" (stay on step 1) or
     "already onboarded" (continue to Home). The code tells them apart.
4. **The first Home visit** shows a one-time welcome card: "+100 coins to start", and three
   ways to play (Battle, Practice, Arena).

## 2. Home

Sections load and fail independently; each has a skeleton, an error with retry, and an empty
state.

1. **Header.** Avatar (opens Profile), "Hi, name", the bell with the unread count (opens the
   Inbox), and the trophy (opens Leaderboards).
2. **Hero card:**
   - the overall rating, with "—" and "Play 1 rated battle to get a rating" for new players;
   - the leaderboard rank, or "Unranked · 7 more rated battles";
   - coins, with a tap opening Wallet;
   - buttons for Play, Practice and Arena.
3. **Live and next.** An ongoing game or search ("You're searching… Return"), or a tournament
   you're registered for ("Round 2 starts in 1:12 · Open").
4. **Play tiles:** Play 1v1, Play with Friend and Group Battle.
5. **Continue practice**, and the **Coach tip** (the top tip, one button).
6. **Today's missions** (3), each with progress and one tap to start. The streak flame and day
   count show here too.
7. **Leaders this week:** the top 3 of the weekly XP board plus your position, and "See all" to
   open Leaderboards.

## 3. Quick Battle (1v1), the core flow

**Setup (Battle tab)**
1. **Pick a subject** from chips filtered by your exam. The last choice is preselected.
2. **Pick a chapter** in a sheet:
   - "All chapters", or one chapter with its question count and your Strong/Needs work word;
   - a chapter that isn't battle-ready shows "Coming soon" and can't be picked.
3. **Pick Rated or Casual:**
   - Rated is free and changes your rating. It shows your subject rating, or "New".
   - Casual costs 5 coins, the winner takes 10, and it doesn't touch the rating. Your balance
     shows beside it. With under 5 coins, Casual is disabled with the hint "Earn coins from
     missions".
4. **Find opponent.**
   - If you're busy elsewhere (a room, a tournament starting in under 5 minutes, another
     device), a sheet says where, with **Go there** or **Leave it**.
   - A cooldown shows "Too many cancelled matches. Try again in 4:32" with a live countdown.

**Searching**
5. **The searching screen:**
   - a pulse animation, the elapsed time, and a Cancel button;
   - a status line: "Looking in Kinematics…", then after 15 s "Widened to all of Physics".
   - You can leave the screen and keep browsing. A pill at the top of every screen says
     "Searching · 0:32", and tapping it returns here.
6. **At 45 s**, a sheet offers **Keep searching**, **Play a Practice Bot** (unrated, no coins),
   **Invite a friend**, or **Cancel**.
   - Choosing the bot cancels the queue first, which refunds a Casual entry.
   - The search stops by itself at 105 s: "No one was available. Try the Practice Bot or invite
     a friend."
7. **If the app goes to the background** for more than 10 s, the search stops. On return:
   "Your search stopped while you were away." Coins are refunded automatically, and the inbox
   records it.

**Match**
8. **Opponent found.** The VS screen shows both avatars, names, ratings and levels, your record
   against this opponent ("You 3 – 1 Rahul"), and the chapter mix ("Kinematics + Laws of
   Motion").
   - It appears wherever you are in the app. A match found while you were browsing takes over the
     screen with a 3-second "Match found!" before the VS screen.
9. **Ready.** The app sends ready automatically once the VS screen is up.
   - **The opponent never gets ready** (10 s): "Your opponent didn't join." You go back to the
     front of the queue with your original waiting time, and see "Searching again…".
   - **You never get ready**, for example because the app was in the background: the match is
     cancelled and Casual coins are refunded. It counts toward the cooldown, and the inbox says so.
10. **Countdown** 3-2-1.
11. **Questions**, 7 × 15 s. For each one:
    - The question appears at the same moment for both players. The timer ring counts down from
      the server deadline.
    - You tap an option, and it locks as "Answered".
    - The opponent's avatar shows a tick when they've answered (never what they picked).
    - **The reveal:**
      - the correct option turns green; your wrong pick turns red and shakes;
      - both players' picks, points and times are shown;
      - you get "You were 1.2 s faster" or "Rahul was faster".
    - The next question follows after 3 s.
12. **Problems during the match:**
    - **Opponent disconnects:** "Rahul is reconnecting… 23 s". After the grace period: "Rahul
      left. You win."
    - **You disconnect:** a "Reconnecting…" banner appears, and the game resumes on return (the
      clock never pauses). After the grace period, the result shows "You were away too long".
    - **You leave on purpose:** Leave, then a confirmation ("You'll lose this match"), then a
      forfeit.
    - **Opening the app on another phone** moves the game there. The first phone shows "Playing on
      another device".

**Result**
13. **The result screen:**
    - **Victory**, **Defeat** or **Draw**, with the final scores;
    - a row of 7 dots (✓/✗, fast/slow);
    - the reason when it wasn't normal: "Rahul left", "Time ran out".
    - "Results syncing…" shows until settlement arrives.
14. **Settlement fills in:**
    - the rating change (animated), and **your new rank**: "You're now #42 in Physics · ↑5";
    - coins and XP, with a level-up celebration if one happened;
    - mission progress, the streak, and any achievement earned;
    - **one tip line**: "You were slower on 4 of 7. Try a timed set in Kinematics."
15. **Buttons:**
    - **Rematch** (Casual only; both must accept within 15 s, up to 3 in a row);
    - **Play again** (same settings, back to searching);
    - **Review answers**: every question with both picks, times, the correct answer, the
      explanation and a bookmark button;
    - **Done**, back to the Battle tab.
16. **Later**, the match is in **Profile → History** with the same review. Coins are listed in the
    **Wallet**, rating changes are on the **profile rating chart**, and any refund or forfeit
    notice is in the **Inbox**.

## 4. Practice Bot
It starts only from the 45 s sheet, or from "Practise vs Bot" on the Battle tab, which is always
available. It is the same game flow as Quick Battle, with these differences:
- the opponent card is clearly labelled "Practice Bot";
- no rating and no coins, half XP, and no speed labels;
- the result screen says "Practice game · not rated".

## 5. Play with Friend

1. **Where it starts:**
   - Battle → Play with Friend;
   - Home tile;
   - Social → a friend → Challenge;
   - the 45 s sheet → Invite a friend.
2. **Setup:** subject, chapter or All, 5/7/10 questions and 10/15/20/30 s. Then **Create**, which
   calls `POST /v1/rooms`.
3. **Lobby:**
   - the code in big letters, **Share link** (Android share sheet) and **Copy code**;
   - **Invite friends**: a list with presence, and "Busy" chips;
   - your friend's slot shows "Waiting…";
   - a new user with no friends sees Share link as the main button.
4. **The friend joins** in one of three ways:
   - the in-app invite banner, **Accept** or **Decline**;
   - the notification;
   - the link (`/j/K7M2QX` opens the app, or the Play Store, then onboarding, then the lobby);
   - or Battle → **Join with code** (6 boxes, with paste).
5. **Starting.** Both get ready, and the host taps **Start** (or it auto-starts 3 s after both are
   ready). The game flow is the same as Quick Battle, but unrated and free.
6. **After the game:** Rematch (both accept within 30 s), change settings, or leave.
7. **Endings:**
   - "Invite expired" after 2 min;
   - "Your friend declined";
   - "The lobby closed because the host left" (after 60 s);
   - a code that doesn't exist or has expired: "That code isn't active. Ask for a new one."

## 6. Group Battle (2–8 players)
It works like a friend room, but **the host controls the room**:
- settings (in the lobby only), start (needs 2 or more connected), kick, lock, transfer host, and
  end.
- **Joining late:** late joiners get 0 for questions they missed, and can only spectate after the
  halfway point.
- **Between questions** (if the setting is on): a mini leaderboard with the top 3, your position,
  and the change since the last question.
- **At the end:**
  - a **podium** for 1st to 3rd, and the full ranking with points and correct answers;
  - "You finished 4th of 7";
  - XP (20 for a win, 10 for taking part);
  - **Play again** keeps the room for 3 minutes.
- **If the host leaves**, the earliest joiner becomes host, and everyone sees "Neha is now the
  host".

## 7. Arena: tournaments

1. **The Arena tab:**
   - filters Open, Upcoming, Live and Finished;
   - tournament cards with subject colour, badges, entry fee, prize pool, players/capacity and a
     start countdown;
   - **My tournaments** pinned at the top.
2. **Tournament detail.** It has three tabs:
   - **Overview:** rules (rounds, 10 questions × 15 s, rated), schedule, entry fee, prize table for
     the current player count, and registered count;
   - **Standings**;
   - **My games**.
3. **Register.**
   - A confirmation sheet shows the fee and the refund rules. The coins are held, not spent yet.
   - "Full" disables the button. With too few coins, it shows "You need 15 coins".
   - **Withdraw** before the start gives a full refund.
4. **Reminders** (inbox, plus push when enabled): at 1 h and 15 min before the start.
5. **Check-in**, 15 → 2 min before the start:
   - one tap from the card, the detail or the notification;
   - **automatic** if the app is open and connected during the window;
   - a player not checked in by the start is refunded and dropped. The inbox says "You didn't
     check in; your 15 coins were returned".
   - From 5 min before the start, quick battles can't be started ("Your tournament starts
     soon").
6. **At the start:**
   - **Enough players:** round 1 pairs, and each player gets a full-screen "Round 1: you vs Aman.
     Join (90 s)" wherever they are in the app.
   - **Not enough players:** "Cancelled: not enough players. Your coins are back."
7. **Each round** is a normal match. A player who doesn't join within 90 s gives the opponent a
   forfeit win. **A bye** shows "You have a bye this round (+1 point)".
8. **The live lobby between rounds:**
   - "Round 2 of 5", with "Pairing in 0:48" or "Live";
   - your record (2–0), points and **current rank**;
   - top standings, and your next opponent once paired.
   - Leaving the app is fine; the next round's banner calls you back.
9. **Finish:**
   - **Final standings**, and your final rank ("You finished #3 of 64");
   - the prize, credited automatically ("+120 coins");
   - XP, and the achievement for a top-3 finish.
   - All of it is kept in **Profile → Tournaments** and the Inbox.
10. **Leaving mid-tournament:** after a confirmation, the player keeps their rank but can't win a
    prize and gets no refund.

## 8. Leaderboards: who is leading where

- **Where they open:** the Home trophy, "Leaders this week", the rank line on the result screen,
  and Profile.
- **The leaderboards hub** has one card per board. Each card shows the **#1 player** (avatar, name,
  value), **your position**, and your change since yesterday.

| Board | Ranks by | Who is on it |
|---|---|---|
| **This week** | XP earned this IST week (Mon–Sun); resets Monday 00:00 IST | Everyone with any XP this week, so new players appear immediately |
| **Overall rating** | Rated battles and tournaments, all subjects | Players with at least 10 rated games and settled ratings |
| **Physics / Chemistry / Biology / Maths** | Subject rating | Same rule, per subject |
| **Friends** | You and your friends, by weekly XP or rating | You and your friends |

- **Exam filter.** Every board can be filtered to **NEET** or **JEE** players (by each player's
  goal).
- **Board screen:**
  - the top 100, with your **sticky row** at the bottom showing your rank and the 10 above and
    below you;
  - tapping a row opens that player's public profile.
- **Not on the board yet:** "Play 7 more rated battles to appear on this board", with a progress
  bar and a Play button.
- **Last week's champions:** the top 3 of last week, kept for the week.
- **Moving up:** after a rated game or tournament, the result screen shows the rank change. Big
  moves (entering the top 100, 10 or 3) are also inbox items.

## 9. Learn and practice
Specified in `docs/api-learn.md`. The steps:
1. Learn tab, then a subject, then a chapter sheet (topic, count, difficulty, timed), then
   **Start**.
2. Each question gets instant feedback and an explanation. Answers are saved even offline.
3. **Summary**, with the score, time, topics, XP and one tip. Then **Practise again** or **Done**.

Other routes in: Continue practice, Review due, Bookmarks, a tip's button, and search (in a later
slice).

## 10. Social
- **Friends:**
  - presence: online, in a battle, in a tournament or offline;
  - Challenge, which opens a friend duel;
  - remove, block and report.
- **Requests.** Search by username, then Add. They can accept or decline.
  - Minors only receive requests from people they have played.
- **Rivals:** people you've played 3+ times in 60 days, with the head-to-head record and
  **Challenge**.
- **Activity:** friends' wins, podiums, level-ups and streaks.
- **Empty states:**
  - no friends: "Add friends by username or share your invite link";
  - no rivals: "Play more battles to find rivals".

## 11. Inbox (the bell)
Every notification is kept here, and tapping one opens its destination. It includes:
- invites and friend requests;
- tournament reminders, check-ins and results;
- prizes, refunds and cancellations;
- missions completed, level-ups, achievements, and big rank moves.

Items are unread until tapped, and "Mark all read" is available. Push notifications (when enabled)
mirror inbox items and open the same destination.

## 12. Profile, history and settings

**Profile (yours)**
- The header, and the level with its XP bar.
- **Ratings** per subject with rank.
- W/D/L, accuracy, questions answered, and streaks.
- **History tabs:**
  - **Battles**: every match with its result, opens the review;
  - **Tournaments**: final rank and prize;
  - **Practice**: sessions with the score.
- **Achievements.**

**Public profile (others)** shows the avatar, name, level, ratings, recent form and your record
against them. The actions are Challenge, Add friend, Block and Report.

**Wallet** shows the balance and the **coins history**: every credit and debit with its reason and
a link to its source (match, tournament, mission).

**Settings**
- profile and goal;
- privacy;
- notifications by type;
- sound and haptics, and theme;
- devices (sign out one, or all others);
- licences and about;
- sign out;
- delete account (restorable for 7 days).

## 13. Account lifecycle
- **Signing out** ends this device's session and returns to Sign-in. Signing out other devices
  takes effect on their next request.
- **An expired session** (refresh token rejected) shows Sign-in with "Please sign in again."
- **Banned:** a notice with the reason category and the appeal contact. Nothing else is
  reachable.
- **Delete:**
  - re-authenticate, then confirm;
  - the app signs out;
  - signing in within 7 days offers "Restore my account".

## 14. Always-on behaviour
- **Live banner layer.** Time-critical events appear on top of any screen:
  - match found;
  - tournament check-in and round ready;
  - an invite received;
  - a rematch request;
  - "Searching…" and "Tournament live" pills.

  The realtime connection stays open while you're queued, in a room or registered in a
  tournament that is about to start or is running, whatever tab you're on.
- **Offline.**
  - A banner shows; cached screens stay usable.
  - Practice answers queue up.
  - Live actions (search, join) are disabled with "You're offline".
- **Background and killed app.**
  - Live games keep running on the server within the grace rules.
  - On return, the app resumes the game or shows what happened.
- **Back button.** Every screen goes back. Live game screens ask before leaving, because leaving
  forfeits.

## 15. Tracking

**For the student:** everything they did can be found again.

| What | Where |
|---|---|
| Battles and reviews | Profile → History → Battles |
| Tournaments | Profile → History → Tournaments |
| Practice sessions | Profile → History → Practice |
| Coins | Wallet → Coins history |
| XP and level | Profile header, level-ups in the Inbox |
| Rating over time | Profile → rating chart (a simple dot chart) |
| Ranks | Leaderboards (with the daily change) |
| Every automatic outcome | Inbox |

**For the team** (product analytics): the server records funnel events without personal details,
kept for 180 days. The funnels:
- **Activation:** `app_first_open`, `sign_in`, `onboarding_step`, `onboarding_done`,
  `first_battle`, `first_practice`.
- **Battle:** `mm_join`, `mm_widened`, `mm_timeout_choice`, `mm_found`, `match_ready_timeout`,
  `match_started`, `match_finished {result, reason}`, `rematch_offered`, `rematch_accepted`,
  `review_opened`.
- **Friend and group:** `room_created`, `invite_sent`, `invite_accepted`, `room_started`,
  `room_finished`.
- **Tournament:** `t_viewed`, `t_registered`, `t_checked_in`, `t_round_played`, `t_finished`,
  `t_withdrawn`.
- **Practice and tips:** `practice_started`, `practice_finished`, `tip_shown`, `tip_acted`,
  `tip_dismissed`.
- **Retention:** `daily_active`, `mission_completed`, `streak_extended`, `leaderboard_viewed`,
  `notification_opened`.

The app sends only a few screen-level events (`POST /v1/events`, names from an allowlist). All the
rest are recorded by the server when the action happens.
