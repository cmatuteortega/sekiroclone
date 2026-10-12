function love.conf(t)
    t.identity = "frog-pond"
    t.version = "11.4"
    t.window.title = "Frog"
    t.window.width = 1280
    t.window.height = 720
    t.window.resizable = true
    t.window.vsync = 1
    t.modules.audio = false
    t.modules.sound = false
end
