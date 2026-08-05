fx_version 'cerulean'
game 'gta5'

author 'kingfabrizios'
description 'leo_mdt - simple NUI MDT prototype (openable via /mdt command)'
version '0.1.0'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/script.js',
    'html/style.css'
}

client_script 'client.lua'

-- depends on qb-core for permissions/integration
dependency 'qb-core'
