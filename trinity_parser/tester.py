# THIS FILE IS OLD. BUT IT STILL WORKS AND WE ARE KEEPING IT FOR BASIC TESTING

from main import parse_code, parse_file
import os

def main():
    FILENAME = "trinity_ai_sub" # do not include .s

    os.getcwd()
    fp = os.path.join(os.getcwd(), "basic_examples", f"{FILENAME}.s") # Add file name here

    with open(fp, 'r') as f:
        code = f.read()
        result = parse_code(code)
        print(repr(result))

    print(f"Wrote {parse_file(fp)}")


main()