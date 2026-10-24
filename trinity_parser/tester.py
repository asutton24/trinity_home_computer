from main import parse_code as parse_code

def main():
    fp = "../basic_examples/FILE_NAME_HERE.s" # Add file name here

    with open(fp, 'r') as f:
        code = f.read()
        result = parse_code(code)
        print(result)