from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from trinity_parser.main import parse_code, parse_file

def main():
    FILENAME = "trinity_ai_sub" # do not include .s

    fp = PROJECT_ROOT / "basic_examples" / f"{FILENAME}.s" # Add file name here

    with open(fp, 'r', encoding='utf-8') as f:
        code = f.read()
        result = parse_code(code)
        print(repr(result))

    print(f"Wrote {parse_file(fp)}")


if __name__ == "__main__":
    main()