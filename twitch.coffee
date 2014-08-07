rest = require 'restler'
winston = require 'winston'
clog = winston.info

client_id = '2ejh93vbsr014gov82rpvry7v3asjc3'

Twitch = rest.service ((cid) ->
  @defaults.headers = {
    'User-Agent': 'twitch-blocks/1.0 (nodejs)'
    'Client-ID': cid
    'Accept': 'application/vnd.twitchtv.v3+json'
  }
  @
), {
  baseURL: 'https://api.twitch.tv/'
}, {
  wrap: (fn) ->
    (result) ->
      if result instanceof Error
        clog 'Api error:', result.message
        @retry 1000
      else
        clog 'got response for', @request.path
        fn result
}

module.exports = new Twitch client_id
