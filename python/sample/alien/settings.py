class Settings:

    def __init__(self):
        # 屏幕设置
        self.screen_width = 1200
        self.screen_height = 800
        self.bg_color = (230, 230, 230)

        # 移动速度
        self.ship_speed = 1.5
        self.ship_limit = 3

        # 子弹设置
        self.bullet_speed = 4.0
        self.bullet_width = 3
        self.bullet_height = 15
        self.bullet_color = (60, 60, 60)
        self.bullet_limit = 10

        # alien 速度
        self.alien_speed = 1.0
        # fleet_drop_speed 表示向下移动的速度
        self.fleet_drop_speed = 2
        # fleet_direction = 1 表示向右移动，-1表示向左移动
        self.fleet_direction = 1
