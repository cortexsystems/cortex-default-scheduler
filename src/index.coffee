{DefaultScheduler} = require './scheduler'

init = ->
  scheduler = new DefaultScheduler()
  window.CortexScheduler = scheduler

  onStart = ->
    window.Cortex.scheduler.onStart (strategy) ->
      scheduler.start window.Cortex, strategy

  window.addEventListener 'cortex-ready', onStart

module.exports = init()
