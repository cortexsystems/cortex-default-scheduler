promise = require 'promise'

DEFAULT_KEY                       = '__default'
BLACK_SCREEN                      = '__bs'
BUFFERED_VIEWS_PER_APP            = 2
# Health checks are disabled right after the scheduler starts for
# HC_WARMUP_DURATION msecs.
HC_WARMUP_DURATION                = 60 * 1000
# Time between two run() calls. Scheduler will fail the health checks
# when this threshold is exceeded.
HC_RUN_CALL_THRESHOLD             = 3 * 60 * 1000
# Time between two successful renders. Scheduler will fail the health
# checks when this threshold is exceeded.
HC_SUCCESSFUL_RUN_CALL_THRESHOLD  = 3 * 60 * 1000

class DefaultScheduler
  constructor: ->
    @_currentApp          = undefined
    @_priorityIndex       = 0
    @_appIndex            = 0
    @_queues              = {}
    @_beginTime           = 0
    @_endTime             = 0
    @_activePrepareCalls  = {}
    @_appViewIndex        = {}

    @_totalAppSlots       = 0
    @_failedAppSlots      = 0

  start: (@_api, @_strategy) ->
    @_startTime             = new Date().getTime()
    @_lastRunTime           = new Date().getTime()
    @_lastSuccessfulRunTime = new Date().getTime()

    @_apps = @_extractAppList @_strategy
    @_initPriorityQueues()

    @_api.scheduler.onAppCrash @_onAppCrash

    @_run()

    @_api.app.registerHealthCheck @_onHealthCheck

  _onAppCrash: (appId) =>
    console.log "Received an app crash: #{appId}"
    @_queues[appId] = "#{DEFAULT_KEY}": []
    @_activePrepareCalls[appId] = 0

  _onHealthCheck: (report) =>
    now = new Date().getTime()
    if now < @_startTime + HC_WARMUP_DURATION
      # Ignore health checks during the warm up period.
      report status: true
      return

    if now > @_lastRunTime + HC_RUN_CALL_THRESHOLD
      # No run() calls.
      report status: false, reason: 'Scheduler has stopped working.'
      return

    if now > @_lastSuccessfulRunTime + HC_SUCCESSFUL_RUN_CALL_THRESHOLD
      # No successfull render() calls.
      report
        status: false
        reason: "Scheduler hasn't rendered any content for too long."
      return

    report status: true

  _run: =>
    if not @_strategy? or @_strategy.length == 0
      throw new Error 'Scheduler cannot run without a strategy'

    @_lastRunTime = new Date().getTime()
    @_prepareApps()
    @_runStep()

  _runStep: ->
    new promise (resolve, reject) =>
      if @_priorityIndex >= @_strategy.length
        @_priorityIndex = 0
        @_appIndex = 0

      @_tryPriority @_priorityIndex, @_appIndex
        .then =>
          @_failedAppSlots = 0
          @_lastSuccessfulRunTime = new Date().getTime()
          if @_priorityIndex == 0
            # We are at the top level. Try the next app in this priority level.
            @_appIndex = @_appIndex + 1
            if @_appIndex >= @_strategy[@_priorityIndex].length
              @_appIndex = 0
          else
            # An app in a lower level priority got rendered. Start from the top
            # level in the next cycle.
            @_priorityIndex = 0
            @_appIndex = 0
          process.nextTick @_run
          resolve()
        .catch (e) =>
          # All apps in this priority level has failed. Move to the next level.
          @_priorityIndex += 1
          @_failedAppSlots += 1
          @_appIndex = 0
          if @_failedAppSlots >= @_totalAppSlots
            @_failedAppSlots = 0
            # All priority levels tested. Slow down and notify user.
            @_api.scheduler.trackView BLACK_SCREEN
            global.setTimeout @_run, 1000
          else
            process.nextTick @_run
          reject e

  _tryPriority: (priorityIndex, appIndex) ->
    new promise (resolve, reject) =>
      if (not @_strategy or priorityIndex >= @_strategy.length \
          or priorityIndex < 0)
        return reject()

      priority = @_strategy[priorityIndex]
      if appIndex < 0 or appIndex >= priority.length
        return reject()

      @_tryPriorityApp priority, appIndex
        .then resolve
        .catch =>
          process.nextTick =>
            @_tryPriority priorityIndex, appIndex + 1
              .then resolve
              .catch reject

  _tryPriorityApp: (priority, appIndex) ->
    new promise (resolve, reject) =>
      if not priority? or appIndex >= priority.length or appIndex < 0
        return reject()

      @_tryApp priority[appIndex]
        .then resolve
        .catch reject

  _tryApp: (app) ->
    new promise (resolve, reject) =>
      if not @_queues or not (app of @_queues)
        return reject()

      queue = @_queues[app]

      contentIds = Object.keys(queue)
      if contentIds.length == 0
        return reject()

      if app not in @_appViewIndex
        @_appViewIndex[app] = 0

      view = @_findView(app, queue, contentIds, @_appViewIndex[app] + 1)
      if view?
        return @_render app, view
          .then resolve
          .catch reject

      reject()

  _findView: (app, queue, contentIds, index) ->
    if index >= contentIds.length
      index = 0

    contentId = contentIds[index]
    views = queue[contentId]
    if views.length > 0
      @_appViewIndex[app] = index
      return views.shift()

    if @_appViewIndex[app] == index
      return

    return @_findView(app, queue, contentIds, index + 1)

  _render: (app, view) ->
    console.log "Rendering #{app}/#{view.contentId}/#{view.viewId}."
    st = new Date().getTime()
    new promise (resolve, reject) =>
      @_api.scheduler.hideRenderShow @_currentApp, view.viewId, app
        .then =>
          et = new Date().getTime()
          console.log """#{app}/#{view.contentId}/#{view.viewId} rendered \
            in #{et - st} msecs."""
          @_currentApp = app
          @_api.scheduler.trackView app, view.contentLabel
          resolve()
        .catch reject

  _prepareApps: ->
    for app, s of @_apps
      appQ = @_queues?[app]
      reqCnt = 0
      if appQ?
        viewCnt = 0
        for v, q of appQ
          viewCnt += q?.length || 0
        reqCnt = BUFFERED_VIEWS_PER_APP - viewCnt
      else
        reqCnt = BUFFERED_VIEWS_PER_APP

      reqCnt = reqCnt - @_activePrepareCalls[app]
      if reqCnt > 0
        for i in [1..reqCnt]
          @_prepare app

  _prepare: (app) ->
    new promise (resolve, reject) =>
      @_activePrepareCalls[app] = @_activePrepareCalls[app] + 1
      @_api.scheduler.prepare app
        .then (resp) =>
          @_activePrepareCalls[app] = @_activePrepareCalls[app] - 1
          if not not resp?.viewId
            viewId = resp.viewId
            contentId = resp?.contentId || DEFAULT_KEY
            contentLabel = resp?.contentLabel
            if not (contentId of @_queues[app])
              @_queues[app][contentId] = []
            @_queues[app][contentId].push
              viewId:       viewId
              contentId:    contentId
              contentLabel: contentLabel
          resolve()
        .catch (e) =>
          @_activePrepareCalls[app] = @_activePrepareCalls[app] - 1
          console.error "prepare() call failed for app #{app}.", e
          reject e

  _initPriorityQueues: ->
    @_queues = {}
    @_activePrepareCalls = {}
    for app, s of @_apps
      @_queues[app] = "#{DEFAULT_KEY}": []
      @_activePrepareCalls[app] = 0
      @_appViewIndex[app] = 0

  _extractAppList: (strategy) ->
    apps = {}
    for priority in strategy
      for app in priority
        @_totalAppSlots += 1
        apps[app] = true

    apps

module.exports = {
  DefaultScheduler,
  DEFAULT_KEY,
  BLACK_SCREEN,
  BUFFERED_VIEWS_PER_APP,
  HC_WARMUP_DURATION,
  HC_RUN_CALL_THRESHOLD,
  HC_SUCCESSFUL_RUN_CALL_THRESHOLD
}
