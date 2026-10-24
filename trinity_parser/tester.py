from main import parse_code as parse_code
import os

def main():
    FILENAME = "trinity_ai_add" # do not include .s

    os.getcwd()
    fp = os.path.join(os.getcwd(), "basic_examples", f"{FILENAME}.s") # Add file name here

    with open(fp, 'r') as f:
        code = f.read()
        result = parse_code(code)
        print(repr(result))

    fp = os.path.join(os.getcwd(), "output_examples", f"{FILENAME}.bin") # Add file name here
    
    with open(fp, 'w') as f:
        f.write(result)

main()