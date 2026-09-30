import 'package:flutter_test/flutter_test.dart';
import 'package:haro_app/features/workspace/steps/code/editor/editor_symbols.dart';

List<String> at(String lang, String source, int line, {int limit = 2}) {
  final lines = source.split('\n');
  return enclosingSymbols(
    lang: lang,
    lineCount: lines.length,
    lineAt: (i) => lines[i],
    cursor: line,
    limit: limit,
  );
}

void main() {
  group('dart', () {
    const src = '''import 'a.dart';

class Rates extends Base {
  Rates(this.x);

  final int x;

  int rate(int w) {
    if (w > 0) {
      return x * w;
    }
    return 0;
  }

  Widget build(
    BuildContext context,
  ) {
    return Text('a');
  }
}

void main() {
  print('hi');
}
''';

    test('method inside a class gives class then method', () {
      expect(at('dart', src, 9), ['Rates', 'rate']);
    });

    test('control flow lines are not declarations', () {
      expect(at('dart', src, 8), ['Rates', 'rate']);
      expect(at('dart', src, 9, limit: 1), ['rate']);
    });

    test('a signature that wraps still names the method', () {
      expect(at('dart', src, 17), ['Rates', 'build']);
    });

    test('a top-level function has no class', () {
      expect(at('dart', src, 22), ['main']);
    });

    test('on the declaration line itself', () {
      expect(at('dart', src, 7), ['Rates', 'rate']);
    });

    test('a field or the file top has none', () {
      expect(at('dart', src, 5), ['Rates']);
      expect(at('dart', src, 0), isEmpty);
    });

    test('a call that wraps is not a declaration', () {
      const call = '''void f() {
  final x = compute(
    a,
    b,
  );
}
''';
      expect(at('dart', call, 3), ['f']);
    });
  });

  group('typescript', () {
    const src = '''import { zone } from './zones';

export class RateTable {
  private cache = new Map();

  async rate(w: number): Promise<number> {
    if (w > 0) {
      return 1;
    }
    return 0;
  }
}

export const total = (a: number) => {
  return a + 1;
};

export function other() {
  return 2;
}
''';

    test('class method', () {
      expect(at('typescript', src, 7), ['RateTable', 'rate']);
    });

    test('arrow function assigned to a const', () {
      expect(at('typescript', src, 14), ['total']);
    });

    test('function declaration', () {
      expect(at('javascript', src, 18), ['other']);
    });

    test('if / for lines are not methods', () {
      expect(at('typescript', src, 8, limit: 5), ['RateTable', 'rate']);
    });
  });

  group('python', () {
    const src = '''import os

class Repo:
    def get(self, key):
        if key:
            return 1

    async def put(self, key):
        return 2


def helper():
    return 3
''';

    test('method under a class', () {
      expect(at('python', src, 5), ['Repo', 'get']);
    });

    test('async method', () {
      expect(at('python', src, 8), ['Repo', 'put']);
    });

    test('a blank line belongs to the code above it', () {
      expect(at('python', src, 6), ['Repo', 'get']);
    });

    test('top-level function', () {
      expect(at('python', src, 12), ['helper']);
    });
  });

  group('go and rust', () {
    test('go method shows receiver type', () {
      const src = '''package main

type Server struct{}

func (s *Server) Start() error {
	if s == nil {
		return nil
	}
	return nil
}
''';
      expect(at('go', src, 6), ['Server.Start']);
    });

    test('rust fn inside impl', () {
      const src = '''pub struct Foo;

impl Foo {
    pub fn new() -> Self {
        Foo
    }

    pub async fn run(&self) {
        let x = 1;
    }
}
''';
      expect(at('rust', src, 4), ['impl Foo', 'new']);
      expect(at('rust', src, 8), ['impl Foo', 'run']);
    });

    test('rust impl Trait for Type names the type', () {
      const src = '''impl Display for Foo {
    fn fmt(&self) {
        x
    }
}
''';
      expect(at('rust', src, 2), ['impl Foo', 'fmt']);
    });
  });

  test('an unknown language yields nothing', () {
    expect(at('cobol', 'IDENTIFICATION DIVISION.', 0), isEmpty);
    expect(
      enclosingSymbols(lang: null, lineCount: 1, lineAt: (_) => 'x', cursor: 0),
      isEmpty,
    );
  });

  test('cursor past the end is clamped and an empty file is safe', () {
    expect(at('python', 'def a():\n    pass', 99), ['a']);
    expect(
      enclosingSymbols(
        lang: 'dart',
        lineCount: 0,
        lineAt: (_) => '',
        cursor: 0,
      ),
      isEmpty,
    );
  });
}
