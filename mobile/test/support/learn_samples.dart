/// Response samples from docs/api-learn.md, shared by the parsing and
/// repository tests. Each call returns a fresh, mutable copy.
library;

/// `GET /v1/catalog?goal=neet`.
Map<String, Object?> catalogJson() => {
  'goal': 'neet',
  'version': '4f1c2a',
  'subjects': [
    {
      'slug': 'physics',
      'name': 'Physics',
      'tone': 'sky',
      'icon': 'physics',
      'question_count': 16,
      'chapters': [
        {
          'slug': 'kinematics',
          'name': 'Motion in a Straight Line',
          'order': 1,
          'question_count': 8,
          'battle_ready': true,
          'topics': [
            {'slug': 'speed-velocity', 'name': 'Speed and velocity', 'question_count': 4},
            {'slug': 'equations-of-motion', 'name': 'Equations of motion', 'question_count': 4},
          ],
        },
      ],
    },
  ],
};

/// `GET /v1/me/progress?goal=neet`.
Map<String, Object?> progressJson() => {
  'subjects': [
    {
      'slug': 'physics',
      'answered': 23,
      'correct': 15,
      'chapters': [
        {'slug': 'kinematics', 'answered': 12, 'correct': 7, 'seen': 6, 'label': 'needs_work'},
      ],
    },
  ],
  'reviews_due': 3,
  'continue': {
    'session_id': 's-1',
    'title': 'Physics · Motion in a Straight Line',
    'answered': 12,
    'count': 20,
  },
  'tip': {
    'key': 'weak_topic:physics:projectile-motion',
    'message': 'Focus on Projectile motion. You got 4 of 11 right.',
    'action': 'practice',
    'params': {'subject': 'physics', 'topic': 'projectile-motion', 'count': '10'},
  },
};

/// The `POST /v1/practice/sessions` 201 sample from docs/api-learn.md.
Map<String, Object?> sessionJson() => {
  'session_id': 's-1',
  'mode': 'chapter',
  'title': 'Physics · Motion in a Straight Line',
  'feedback': 'instant',
  'created_at': '2026-09-27T15:00:00Z',
  'expires_at': '2026-09-28T15:00:00Z',
  'per_question_ms': null,
  'time_limit_ms': null,
  'marking': 'none',
  'short': false,
  'questions': [questionJson()],
};

Map<String, Object?> questionJson({int position = 1}) => {
  'ref': 'q_01929f',
  'position': position,
  'stem':
      'A car starts from rest and accelerates uniformly at 2 m s^{-2}. How far does it travel '
      'in 5 s?',
  'options': [
    {'id': 2, 'text': '50 m'},
    {'id': 0, 'text': '10 m'},
    {'id': 3, 'text': '100 m'},
    {'id': 1, 'text': '25 m'},
  ],
  'answer': 1,
  'explanation': 'Starting from rest (u = 0), s = ut + ½at^2 = ½ × 2 × 5^2 = 25 m.',
  'difficulty': 2,
  'category': 'numerical',
  'chapter': {'slug': 'kinematics', 'name': 'Motion in a Straight Line'},
  'topic': {'slug': 'equations-of-motion', 'name': 'Equations of motion'},
  'bookmarked': false,
};

/// `GET /v1/search?q=kine` item (also the shape of a bookmark, without its time).
Map<String, Object?> questionSummaryJson({String ref = 'q_01929f'}) => {
  'ref': ref,
  'stem': 'A car starts from rest and accelerates uniformly at 2 m s^{-2}.',
  'subject': 'physics',
  'chapter': {'slug': 'kinematics', 'name': 'Motion in a Straight Line'},
  'topic': {'slug': 'equations-of-motion', 'name': 'Equations of motion'},
};

/// `GET /v1/me/bookmarks` page.
Map<String, Object?> bookmarksJson({String? nextCursor = 'c2'}) => {
  'items': [
    {...questionSummaryJson(), 'bookmarked_at': '2026-09-27T15:00:00Z'},
    {...questionSummaryJson(ref: 'q_2'), 'topic': null, 'bookmarked_at': '2026-09-26T10:00:00Z'},
  ],
  'next_cursor': nextCursor,
};

/// `GET /v1/questions/{ref}`: options in authored order.
Map<String, Object?> questionDetailJson() => {
  ...questionJson(),
  'options': [
    {'id': 0, 'text': '10 m'},
    {'id': 1, 'text': '25 m'},
    {'id': 2, 'text': '50 m'},
    {'id': 3, 'text': '100 m'},
  ],
  'bookmarked': true,
}..remove('position');

/// `GET /v1/passages`.
Map<String, Object?> passagesJson() => {
  'items': [
    {
      'id': '0192a0e4-5f1c-7b2a-9d11-5c8e2f4a7b01',
      'title': 'Galileo and the falling balls',
      'subject': 'physics',
      'chapter': {'slug': 'kinematics', 'name': 'Motion in a Straight Line'},
      'difficulty': 2,
      'question_count': 3,
      'done': false,
    },
    {
      'id': '0192a0e4-5f1c-7b2a-9d11-5c8e2f4a7b02',
      'title': 'The cell\'s power stations',
      'subject': 'biology',
      'chapter': null,
      'difficulty': 1,
      'question_count': 2,
      'done': true,
    },
  ],
};
