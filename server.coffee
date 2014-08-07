express = require 'express'
http = require 'http'
util = require 'util'
path = require 'path'
reload = require 'reload'
winston = require 'winston'
rest = require 'restler'
twitch = require './twitch'

clog = winston.info

bodyParser = require 'body-parser'
morgan = require 'morgan'
_ = require 'lodash'

app = express()

router = express.Router {}

app.set 'port', process.env.PORT or 8080
app.use morgan 'dev'
app.use bodyParser.urlencoded extended: true
app.use bodyParser.json {}
app.use router

finish = (req, res, o) ->
  body = o
  res.set 'Content-type', 'application/json'
  res.set 'Access-control-allow-origin', '*'
  res.send JSON.stringify body

blockStatus = {}

getBlocks = (channel) ->
  status = {
    channel
    finished: false
    started: Date.now()
  }
  blockStatus[channel] = status
  vod_ids = []
  vod_processed_ids = []
  vods = {}
  summary = {
    total_seconds: 0
    muted_seconds: 0
    unprocessed_seconds: 0
  }
  affected = {}
  get_ids = (api_url) ->
    twitch.get(api_url).on 'complete', twitch.wrap (result) ->
      if result.error?
        status.finished = true
        status.error = result.message
        return
      for video in result.videos
        vod_ids.push video._id
      status.progress = {
        total_vods: result._total
        current_ids: vod_ids.length
      }
      if vod_ids.length < result._total
        get_ids result._links.next
      else
        process_ids()
  process_ids = ->
    if vod_ids.length is 0
      status.finished = true
      status.error = 'Channel has no VoDs'
      return
    for vod_id in vod_ids
      twitch.get('/api/videos/' + vod_id).on 'complete', twitch.wrap (result) ->
        vods[result.api_id] = result
        vod_processed_ids.push result.api_id
        status.progress.current_datas = vod_processed_ids.length
        if vod_processed_ids.length is vod_ids.length
          reduce_chunks()
  reduce_chunks = ->
    for vod_id, video of vods
      if not video.chunks?
        clog vod_id
        continue
      for chunk in video.chunks.live
        summary.total_seconds += chunk.length
        if chunk.upkeep is 'fail'
          summary.muted_seconds += chunk.length
        if chunk.upkeep is null
          summary.unprocessed_seconds += chunk.length
        aff = affected[video.api_id] or {
          total_seconds: 0
          muted_seconds: 0
          unprocessed_seconds: 0
        }
        aff.total_seconds += chunk.length
        if chunk.upkeep is 'fail'
          aff.muted_seconds += chunk.length
        if chunk.upkeep is null
          aff.unprocessed_seconds += chunk.length
        affected[video.api_id] = aff

    pending_vod_infos = 0
    for id, aff of affected
      if aff.muted_seconds is 0
        delete affected[id]
      else
        pending_vod_infos++
        twitch.get('/kraken/videos/' + id).on 'complete', twitch.wrap (result) ->
          o = status.affected[result._id]
          o.url = result.url
          o.title = result.title
          o.recorded = +new Date result.recorded_at
          o.views = result.views
          o.game = result.game
          pending_vod_infos--
          if pending_vod_infos is 0
            status.finished = true

    status = _.extend status, {
      summary, affected
    }

  get_ids "/kraken/channels/#{channel}/videos?broadcasts=true&limit=100"

router.get '/:whatever', (req, res) ->
  res.status 302
  res.set 'Location', '/#' + req.params.whatever
  finish req, res, {}

router.get '/status/:channel', (req, res) ->
  { channel } = req.params
  if not blockStatus[channel]?
    getBlocks channel
  finish req, res, blockStatus[channel]

router.get '/refresh/:channel', (req, res) ->
  { channel } = req.params
  status = "fresh data already exists"
  if not blockStatus[channel]? or blockStatus[channel].started < Date.now() - 19 * 60 * 1000
    getBlocks channel
    status = "success"
  finish req, res, { status }

server = http.createServer app
reload server, app
server.listen app.get('port'), ->
  console.log "server listening on port #{app.get 'port'}"
