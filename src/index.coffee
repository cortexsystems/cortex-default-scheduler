{DefaultScheduler} = require './scheduler'

init = ->
  onStart = ->
    window.Cortex.app.getConfig()
      .then (config) ->
        bufferLenStr = config['cortex.default_scheduler.buffer_len']
        bufferLen = Number.parseInt bufferLenStr
        if isNaN(bufferLen) or bufferLen <= 0
          bufferLen = 2

        scheduler = new DefaultScheduler bufferLen
        window.CortexScheduler = scheduler

        window.Cortex.scheduler.onStart (strategy) ->
          scheduler.start window.Cortex, strategy

      .catch (e) ->
        console.error 'Failed to initialize the scheduler.', e
        throw e

  window.addEventListener 'cortex-ready', onStart

module.exports = init()
