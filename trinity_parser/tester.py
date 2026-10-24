from trinity_parser.main import parse_code as parse_code

def main():
    fp = "../basic_examples/FILE_NAME.s"  # Replace with the path to your test file

    with open(fp, 'r') as f:
        code = f.read()
        result = parse_code(code)
        print(result)