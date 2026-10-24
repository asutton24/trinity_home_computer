# THIS FILE IS OLD. BUT IT STILL WORKS AND WE ARE KEEPING IT FOR BASIC TESTING
# TO MAKE THIS FILE WORK, MAKE THE PARSER RETURN A STRING

from main import parse_code as parse_code
import os

def main():
    FILENAME = "decimal_num" # do not include .s

    os.getcwd()
    fp = os.path.join(os.getcwd(), "basic_examples", f"{FILENAME}.s") # Add file name here

    with open(fp, 'r') as f:
        code = f.read()
        result = parse_code(code)
        print(repr(result))


main()