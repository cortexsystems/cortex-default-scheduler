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

# A basic Cortex scheduler.
#
# This scheduler accepts a strategy and runs one app at a time fullscreen.
# A strategy is a list of priority levels. Lower indexes have higher
# importance. Each priority level consists of a list of applications.
# Priority levels can have multiple instances of the same app. Here is a sample
# strategy:
#
# [
#   ['ads', 'ads', 'editorial']
#   ['editorial', 'static-images']
#   ['static-images']
# ]
#
# The scheduler creates a view queue for each application (@_queues). For the
# above strategy, the scheduler would create 3 view queues. Applications may
# pass a content id with each prepare() call. In this case, the scheduler will
# create additional queues per unique content id.
#
# Priority Behavior:
#
#  - The very first step starts at P0-A0.
#  - During a step, we try a single priority level.
#  - During a step, we try the remaining apps of a priority level.
#  - When a step succeeds, we advance the app index, so next time we try the
#    same priority level, we'll try the next app in that level.
#  - When a step succeeds, if we are not at the top priority level, we reset
#    app indexes of all top level priority levels and start at P0-A0.
#  - When a step fails (no render), we move to the next priority level.
#  - When a step fails and we tried all apps, the scheduler will sleep for
#    some time and report a black screen.
#
# Sample run:
#   P0: ['a', 'b', 'c']
#   P1: ['d', 'e', 'f']
#   P2: ['g', 'h', 'i']
#
# Step 1: Try 'a'. (Assume rendering status to be: Success)
# Step 2: Try 'b'. (Success)
# Step 3: Try 'c'. (Success)
# Step 4: Try 'a'. (Success)
# Step 5: Try 'b'. (Fail)
# Step 6: Try 'c'. (Fail)
# Step 7: Try 'a'. (Fail)
# Step 8: Try 'd'. (Fail)
# Step 9: Try 'e'. (Success)
# Step 10: Try 'a'. (Fail)
# Step 11: Try 'b'. (Fail)
# Step 12: Try 'c'. (Fail)
# Step 13: Try 'f'. (Fail)
# Step 14: Try 'a'. (Fail)
# Step 15: Try 'b'. (Fail)
# Step 16: Try 'c'. (Fail)
# Step 17: Try 'd'. (Fail)
# Step 18: Try 'e'. (Fail)
# Step 19: Try 'f'. (Fail)
# Step 20: Try 'g'. (Success)
# Step 21: Try 'a'...
#
# Unique Content:
# The scheduler guarantees it will show unique content if an app provides
# content ids. The scheduler will skip (not discard) a view, if the currently
# tested app is the same as the currently rendered one and the tested view has
# the same id as the currently rendered view.
#
class DefaultScheduler
  constructor: ->
    # The last successfully rendered app.
    @_currentApp          = undefined
    # The last successfully rendered view.
    @_currentView         = undefined
    # Keeps track of the priority index to be tried during the next step.
    @_priorityIndex       = 0
    # View queues for each app. Each app will start with a default queue, but
    # they can create additional queues by passing a content id with prepare()
    # calls. e.g.
    # @_queues = {
    #   'app1': {
    #     '__default': ['v1', 'v2'],
    #     'content-id-1': ['v3', 'v4']}
    #   'app2': {
    #     '__default': ['v1', 'v2']}
    @_queues              = {}
    # Keeps track of prepare() calls made to the apps in order not to flood
    # apps.
    @_activePrepareCalls  = {}
    # Keeps track of last tried view queue index for each app. For instance,
    # if @_appViewIndex['app1'] is 2, this means we tried the third queue of
    # app1. During the next run, we should try the fourth queue (or first, if
    # it doesn't have four queues) of app1.
    @_appViewIndex        = {}
    # Similar to appViewIndex, this keeps track of tried apps within a priority
    # level.
    @_priorityAppIndex    = []

    # Number of unique apps in a strategy.
    @_totalAppSlots       = 0
    # Failed unique app count so far. When an app renders, this counter will
    # get reset.
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
        # During the previous step we tried all available priority levels and
        # still failed. We need to start from the top.
        @_priorityIndex = 0

      if @_priorityAppIndex[@_priorityIndex] >= \
          @_strategy[@_priorityIndex].length
        @_priorityAppIndex[@_priorityIndex] = 0

      @_tryPriority @_priorityIndex, @_priorityAppIndex[@_priorityIndex]
        .then =>
          @_failedAppSlots = 0
          @_lastSuccessfulRunTime = new Date().getTime()

          # Move to the next app in the same priority level.
          @_priorityAppIndex[@_priorityIndex] += 1

          # Next step will start from the top. We need to reset app indexes in
          # all higher priority levels.
          if @_priorityIndex != 0
            for pi in [0..@_priorityIndex - 1]
              @_priorityAppIndex[pi] = 0
          @_priorityIndex = 0

          process.nextTick @_run
          resolve()
        .catch (e) =>
          # All apps in this priority level has failed. Move to the next level.
          @_priorityIndex += 1
          @_failedAppSlots += 1

          if @_failedAppSlots >= @_totalAppSlots
            @_failedAppSlots = 0
            # All priority levels tested. Slow down and notify user.
            @_api.scheduler.trackView BLACK_SCREEN
            # Reset the current app & view to allow duplicate content to be
            # displayed after a black screen. Not resetting these values
            # will cause a scheduler fail under the following conditions:
            #   - There's only one app
            #   - The app offers unique views
            #   - Currently the app queue has max. number of views for that app
            #   - All views has the same id
            @_currentApp = undefined
            @_currentView = undefined
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
      if contentIds.length == 1 or @_currentApp != app
        # Either the candidate app is different than the last rendered one or
        # the candidate app doesn't provide content ids. In either case we
        # shouldn't check for uniqueness.
        @_appViewIndex[app] = index
        return views.shift()
      else
        for view, idx in views
          if view?.contentId != @_currentView?.contentId
            @_appViewIndex[app] = index
            deleted = views.splice(idx, 1)
            return deleted[0]

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
          @_currentView = view
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
      @_priorityAppIndex.push 0
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
