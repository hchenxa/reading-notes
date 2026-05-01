from random import randint
import plotly.express as px


class Die:

    def __init__(self, num_sides=6):
        self.num_sides = num_sides

    def roll(self):
        return randint(1, self.num_sides)


if __name__ == '__main__':

    die = Die()

    results = []

    for roll_num in range(100):
        result = die.roll()
        results.append(result)

    frequencies = []
    pass_result = range(1, die.num_sides + 1)
    for v in pass_result:
        frequency = results.count(v)
        frequencies.append(frequency)

    fig = px.bar(x=pass_result, y=frequencies)
    fig.show()