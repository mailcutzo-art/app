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
