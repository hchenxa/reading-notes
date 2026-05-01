import csv
from pathlib import Path


if __name__ == '__main__':

    path = Path('./matrix.csv')
    lines = path.read_text().splitlines()

    reader = csv.reader(lines)
    header_row = next(reader)
    print(header_row)

    for i, col in enumerate(header_row):
        print(i, col)

    for row in reader:
        print(row)