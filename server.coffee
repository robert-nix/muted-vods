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
  vod_infos = {}
  total_highlights = 0
  total_broadcasts = 0
  highlights_done = false
  get_ids = (api_url) ->
    twitch.get(api_url).on 'complete', twitch.wrap (result) ->
      if result.error?
        status.finished = true
        status.error = result.message
        return
      if not highlights_done and total_highlights is 0
        total_highlights = result._total
      if highlights_done and total_broadcasts is 0
        total_broadcasts = result._total
      for video in result.videos
        vod_ids.push video._id
        vod_infos[video._id] = video
      status.progress = {
        total_vods: total_broadcasts + total_highlights
        current_ids: vod_ids.length
      }
      if vod_ids.length < status.progress.total_vods
        get_ids result._links.next
      else
        if highlights_done
          process_ids()
        else
          highlights_done = true
          get_ids "/kraken/channels/#{channel}/videos?broadcasts=true&limit=100"
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
    b_summary = {
      total_seconds: 0
      muted_seconds: 0
      unprocessed_seconds: 0
    }
    b_affected = {}
    h_summary = {
      total_seconds: 0
      muted_seconds: 0
      unprocessed_seconds: 0
    }
    h_affected = {}
    for vod_id, video of vods
      highlight = vod_id[0] is 'c'
      summary = if highlight then h_summary else b_summary
      affected = if highlight then h_affected else b_affected
      if not video.chunks?.live?
        clog vod_id
        continue
      offset = 0
      for chunk in video.chunks.live
        # todo: count duration correctly (this math doesn't add up)
        duration = chunk.length
        next_offset = offset + chunk.length
        if offset < video.start_offset and next_offset > video.start_offset
          duration -= video.start_offset - offset
        if offset < video.end_offset and next_offset > video.end_offset
          duration -= next_offset - video.end_offset
        if next_offset < video.start_offset or offset >= video.end_offset or duration <= 0
          offset = next_offset
          continue
        offset = next_offset
        summary.total_seconds += duration
        if chunk.upkeep is 'fail'
          summary.muted_seconds += duration
        if chunk.upkeep is null
          summary.unprocessed_seconds += duration
        aff = affected[video.api_id] or {
          total_seconds: 0
          muted_seconds: 0
          unprocessed_seconds: 0
        }
        aff.total_seconds += duration
        if chunk.upkeep is 'fail'
          aff.muted_seconds += duration
        if chunk.upkeep is null
          aff.unprocessed_seconds += duration
        affected[video.api_id] = aff

    for affected in [b_affected, h_affected]
      for id, aff of affected
        if aff.muted_seconds is 0
          delete affected[id]
        else
          vod_info = vod_infos[id]
          aff.url = vod_info.url
          aff.title = vod_info.title
          aff.recorded = +new Date vod_info.recorded_at
          aff.views = vod_info.views
          aff.game = vod_info.game
    status.finished = true

    status = _.extend status, {
      highlights: {
        summary: h_summary
        affected: h_affected
      }
      broadcasts: {
        summary: b_summary
        affected: b_affected
      }
    }

  get_ids "/kraken/channels/#{channel}/videos?limit=100"

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
  if not blockStatus[channel]? or blockStatus[channel].started < Date.now() - 49 * 60 * 1000
    getBlocks channel
    status = "success"
  finish req, res, { status }

server = http.createServer app
reload server, app
server.listen app.get('port'), ->
  console.log "server listening on port #{app.get 'port'}"
