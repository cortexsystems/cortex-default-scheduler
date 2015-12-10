require './test-case'
expect    = require('chai').expect
sinon     = require 'sinon'
promise   = require 'promise'

{
  DefaultScheduler,
  DEFAULT_KEY,
  BLACK_SCREEN,
  HC_WARMUP_DURATION,
  HC_RUN_CALL_THRESHOLD,
  HC_SUCCESSFUL_RUN_CALL_THRESHOLD,
  PREPARE_TIMEOUT,
  MAX_IMMEDIATE_VIEWS_PER_APP
} = require '../src/scheduler'

describe 'Scheduler', ->
  beforeEach ->
    @hideRenderShow = sinon.stub()
    @prepare = sinon.stub()
    @trackView = sinon.stub()
    @bufferedViewsPerApp = 2
    @api =
      scheduler:
        prepare: @prepare
        hideRenderShow: @hideRenderShow
        trackView: @trackView
    @clock = sinon.useFakeTimers()
    @scheduler = new DefaultScheduler @bufferedViewsPerApp
    @scheduler._api = @api

  afterEach ->
    @clock.restore()

  describe '#_onAppCrash', ->
    it 'should discard views of the crashed apps', ->
      @scheduler._queues =
        'app-id':
          '__default': ['a', 'b']
          'other': ['c']
      @scheduler._activePrepareCalls = 'app-id': 10
      @scheduler._onAppCrash 'app-id'
      expect(@scheduler._queues).to.deep.equal
        'app-id':
          '__default': []
      expect(@scheduler._activePrepareCalls['app-id']).to.equal 0

  describe '#_onRequestFocus', ->
    it 'should return silently when app id is invalid', ->
      @scheduler._apps =
        app1: true
      expect(@scheduler._immediateViewQueues).to.deep.equal {}
      @scheduler._onRequestFocus undefined, {viewId: 'view'}
      expect(@scheduler._immediateViewQueues).to.deep.equal {}
      @scheduler._onRequestFocus '', {viewId: 'view'}
      expect(@scheduler._immediateViewQueues).to.deep.equal {}
      @scheduler._onRequestFocus 'app2', {viewId: 'view'}
      expect(@scheduler._immediateViewQueues).to.deep.equal {}

    it 'should return silently when view id is invalid', ->
      @scheduler._apps =
        app1: true
      expect(@scheduler._immediateViewQueues).to.deep.equal {}
      @scheduler._onRequestFocus 'app1', {}
      expect(@scheduler._immediateViewQueues).to.deep.equal {}
      @scheduler._onRequestFocus 'app1', {viewId: undefined}
      expect(@scheduler._immediateViewQueues).to.deep.equal {}
      @scheduler._onRequestFocus 'app1', {viewId: ''}
      expect(@scheduler._immediateViewQueues).to.deep.equal {}

    it 'should add the view to the immediate queue', ->
      @scheduler._apps =
        app1: true
        app2: true
      @scheduler._immediateViewQueues =
        app1: []
        app2: ['v']
      @scheduler._onRequestFocus 'app1', {viewId: 'v1'}
      expect(@scheduler._immediateViewQueues).to.deep.equal
        app1: [{viewId: 'v1', contentId: undefined, contentLabel: undefined}]
        app2: ['v']

      @scheduler._onRequestFocus 'app1', {viewId: 'v2', contentId: 'v2'}
      expect(@scheduler._immediateViewQueues).to.deep.equal
        app1: [
          {viewId: 'v1', contentId: undefined, contentLabel: undefined}
          {viewId: 'v2', contentId: 'v2', contentLabel: undefined}
        ]
        app2: ['v']
      @scheduler._onRequestFocus 'app2', {
        viewId: 'v3', contentId: 'v3', contentLabel: 'v3'}
      expect(@scheduler._immediateViewQueues).to.deep.equal
        app1: [
          {viewId: 'v1', contentId: undefined, contentLabel: undefined}
          {viewId: 'v2', contentId: 'v2', contentLabel: undefined}
        ]
        app2: ['v', {viewId: 'v3', contentId: 'v3', contentLabel: 'v3'}]

  describe '#_onHealthCheck', ->
    it 'should succeed during the warmup period', ->
      report = sinon.stub()
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith status: true
      report.reset()

      @clock.tick 5000
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith status: true

    it 'should fail when there have been no run calls', ->
      rs = sinon.stub @scheduler, '_runStep', ->
      # warm up
      @clock.tick HC_WARMUP_DURATION
      @scheduler._strategy = [['a']]
      @scheduler._run()
      @clock.tick 200000

      report = sinon.stub()
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith
        status: false
        reason: 'Scheduler has stopped working.'

    it 'should fail when there have been no successful renders', ->
      # warm up
      @clock.tick HC_WARMUP_DURATION * 10
      now = new Date().getTime()
      @scheduler._lastRunTime = now
      @scheduler._lastSuccessfulRunTime = now - 300000

      report = sinon.stub()
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith
        status: false
        reason: "Scheduler hasn't rendered any content for too long."

    it 'should succeed when everything is alright', ->
      @clock.tick HC_WARMUP_DURATION * 10
      now = new Date().getTime()
      @scheduler._lastRunTime = now
      @scheduler._lastSuccessfulRunTime = now

      report = sinon.stub()
      @scheduler._onHealthCheck report
      expect(report).to.have.been.calledOnce
      expect(report).to.have.been.calledWith status: true

  describe '#_runStep', ->
    it 'should try an immediate view first', (done) ->
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        promise.reject()
      ti = sinon.stub @scheduler, '_tryImmediateView', ->
        promise.resolve()
      @scheduler._runStep()
        .then ->
          expect(ti).to.have.been.calledOnce
          expect(tp).to.not.have.been.called
          process.nextTick ->
            expect(run).to.have.been.calledOnce
            done()

    it 'should reset immediate view counters when priority fails', (done) ->
      @scheduler._priorityIndex = 1
      tp = sinon.stub @scheduler, '_tryPriority', ->
        promise.reject()
      @scheduler._apps =
        app1: true
      @scheduler._immediateViewQueues = {}
      @scheduler._consecutiveImmediateRenders =
        app1: 9
      @scheduler._strategy = [
        ['a', 'b'],
        ['c', 'd'],
        ['e']
      ]
      @scheduler._priorityAppIndex = [0, 1, 0]
      @scheduler._runStep()
        .catch =>
          expect(@scheduler._consecutiveImmediateRenders).to.deep.equal
            app1: 0
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 1, 1
          done()

    it 'should reset immediate view counters when priority succeeds', (done) ->
      @scheduler._priorityIndex = 1
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._apps =
        app1: true
      @scheduler._immediateViewQueues = {}
      @scheduler._consecutiveImmediateRenders =
        app1: 9
      @scheduler._strategy = [
        ['a', 'b', 'c', 'd'],
        ['e', 'f', 'g'],
        ['h', 'i']
      ]
      @scheduler._priorityAppIndex = [8, 1, 3]
      @scheduler._totalAppSlots = 9
      @scheduler._failedAppSlots = 4
      @scheduler._runStep()
        .then =>
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 1, 1
          expect(@scheduler._consecutiveImmediateRenders).to.deep.equal
            app1: 0
          done()

    it 'should try an app of a priority', (done) ->
      @scheduler._priorityIndex = 1
      tp = sinon.stub @scheduler, '_tryPriority', ->
        promise.reject()
      @scheduler._immediateViewQueues = {}
      @scheduler._consecutiveImmediateRenders = {}
      @scheduler._strategy = [
        ['a', 'b'],
        ['c', 'd'],
        ['e']
      ]
      @scheduler._priorityAppIndex = [0, 1, 0]
      @scheduler._runStep()
        .catch ->
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 1, 1
          done()

    it 'should only reset the index for the current priority level when \
        priority index is out of bounds', (done) ->
      @scheduler._priorityIndex = 6
      tp = sinon.stub @scheduler, '_tryPriority', ->
        promise.reject()
      @scheduler._immediateViewQueues = {}
      @scheduler._consecutiveImmediateRenders = {}
      @scheduler._strategy = [
        ['a', 'b'],
        ['c', 'd'],
        ['e']
      ]
      @scheduler._priorityAppIndex = [1, 1, 3]
      @scheduler._runStep()
        .catch =>
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 0, 1
          expect(@scheduler._priorityAppIndex).to.deep.equal [0, 1, 3]
          done()

    it 'should reset the app index when it is out of bounds', (done) ->
      @scheduler._priorityIndex = 1
      tp = sinon.stub @scheduler, '_tryPriority', ->
        promise.reject()
      @scheduler._strategy = [
        ['a', 'b'],
        ['c', 'd'],
        ['e']
      ]
      @scheduler._priorityAppIndex = [8, 11, 3]
      @scheduler._runStep()
        .catch =>
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 1, 0
          expect(@scheduler._priorityAppIndex).to.deep.equal [8, 0, 3]
          done()

    it 'should move to the next app when current app renders', (done) ->
      @scheduler._priorityIndex = 1
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._strategy = [
        ['a', 'b', 'c', 'd'],
        ['e', 'f', 'g'],
        ['h', 'i']
      ]
      @scheduler._priorityAppIndex = [8, 1, 3]
      @scheduler._totalAppSlots = 9
      @scheduler._failedAppSlots = 4
      @scheduler._runStep()
        .then =>
          expect(@scheduler._failedAppSlots).to.equal 0
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 1, 1
          expect(@scheduler._priorityIndex).to.equal 0
          expect(@scheduler._priorityAppIndex).to.deep.equal [0, 2, 3]
          process.nextTick ->
            expect(run).to.have.been.calledOnce
            done()

    it 'should reset all top level app indexes when the current app \
        renders', (done) ->
      @scheduler._priorityIndex = 2
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._strategy = [
        ['a', 'b', 'c', 'd'],
        ['e', 'f', 'g'],
        ['h', 'i']
      ]
      @scheduler._totalAppSlots = 9
      @scheduler._failedAppSlots = 4
      @scheduler._priorityAppIndex = [8, 3, 1]
      @scheduler._runStep()
        .then =>
          expect(@scheduler._failedAppSlots).to.equal 0
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 2, 1
          expect(@scheduler._priorityIndex).to.equal 0
          expect(@scheduler._priorityAppIndex).to.deep.equal [0, 0, 2]
          process.nextTick ->
            expect(run).to.have.been.calledOnce
            done()

    it 'should move to the next priority when the current priority \
        fails', (done) ->
      @scheduler._priorityIndex = 1
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> reject()
      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e', 'f'],
        ['e']
      ]
      @scheduler._totalAppSlots = 7
      expect(@scheduler._failedAppSlots).to.equal 0
      @scheduler._priorityAppIndex = [8, 2, 2]
      @scheduler._runStep()
        .catch (e) =>
          expect(@scheduler._failedAppSlots).to.equal 1
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 1, 2
          expect(@scheduler._priorityIndex).to.equal 2
          @scheduler._priorityAppIndex = [8, 2, 2]
          process.nextTick =>
            expect(@trackView).to.not.have.been.called
            expect(run).to.have.been.calledOnce
            done()

    it 'should sleep for a while and notify the user when all priority levels \
        fail', (done) ->
      @scheduler._priorityIndex = 2
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> reject()
      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e', 'f'],
        ['e']
      ]
      @scheduler._totalAppSlots = 7
      @scheduler._failedAppSlots = 6
      @scheduler._priorityAppIndex = [8, 2, 0]
      @scheduler._currentApp = 'a'
      @scheduler._currentView = 'view'
      @scheduler._runStep()
        .catch (e) =>
          expect(@scheduler._failedAppSlots).to.equal 0
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 2, 0
          expect(@scheduler._priorityIndex).to.equal 3
          expect(@trackView).to.have.been.calledOnce
          expect(@trackView).to.have.been.calledWith '__bs'
          expect(@scheduler._currentApp).to.be.undefined
          expect(@scheduler._currentView).to.be.undefined
          expect(run).to.not.have.been.called
          @clock.tick 1000
          expect(run).to.have.been.calledOnce
          done()

    it 'should not notify a black screen when there are still apps that are \
        not failed', (done) ->
      @scheduler._priorityIndex = 2
      run = sinon.stub @scheduler, '_run', ->
      tp = sinon.stub @scheduler, '_tryPriority', ->
        new promise (resolve, reject) -> reject()
      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e', 'f'],
        ['e']
      ]
      @scheduler._totalAppSlots = 7
      @scheduler._failedAppSlots = 3
      @scheduler._priorityAppIndex = [8, 2, 0]
      @scheduler._runStep()
        .catch (e) =>
          expect(@scheduler._failedAppSlots).to.equal 4
          expect(tp).to.have.been.calledOnce
          expect(tp).to.have.been.calledWith 2, 0
          expect(@scheduler._priorityIndex).to.equal 3
          process.nextTick =>
            expect(@trackView).to.not.have.been.called
            expect(run).to.have.been.calledOnce
            done()

  describe '#_run', ->
    it 'should throw when strategy is invalid', ->
      expect(@scheduler._strategy).to.not.be.ok
      expect(=> @scheduler._run()).to.throw
      @scheduler._strategy = []
      expect(=> @scheduler._run()).to.throw

    it 'should try all apps in priority order when everything fails', (done) ->
      @scheduler._priorityIndex = 0
      run = sinon.stub @scheduler, '_run', =>
        if @scheduler._priorityIndex == 3
          expect(ta).to.have.callCount 7
          expect(ta.args[0]).to.deep.equal ['a']
          expect(ta.args[1]).to.deep.equal ['b']
          expect(ta.args[2]).to.deep.equal ['c']
          expect(ta.args[3]).to.deep.equal ['d']
          expect(ta.args[4]).to.deep.equal ['e']
          expect(ta.args[5]).to.deep.equal ['f']
          expect(ta.args[6]).to.deep.equal ['e']
          done()
          return

        @scheduler._runStep()
          .catch (e) =>
            @clock.tick 1000

      ta = sinon.stub @scheduler, '_tryApp', (app) ->
        new promise (resolve, reject) -> reject()

      @scheduler._strategy = [
        ['a', 'b', 'c'],
        ['d', 'e', 'f'],
        ['e']
      ]
      @scheduler._priorityAppIndex = [0, 0, 0]
      @scheduler._run()

  describe '#_tryImmediateView', ->
    it 'should fail when there are no apps', (done) ->
      render = sinon.spy @scheduler, '_render'
      @scheduler._tryImmediateView()
        .catch ->
          expect(render).to.not.have.been.called
          done()

    it 'should fail when there are no views', (done) ->
      render = sinon.spy @scheduler, '_render'
      @scheduler._immediateViewQueues =
        app1: []
        app2: []
      @scheduler._tryImmediateView()
        .catch ->
          expect(render).to.not.have.been.called
          done()

    it 'should fail when all apps exceed threshold', (done) ->
      render = sinon.spy @scheduler, '_render'
      @scheduler._immediateViewQueues =
        app1: ['v1', 'v2']
        app2: ['v3']
      @scheduler._consecutiveImmediateRenders =
        app1: MAX_IMMEDIATE_VIEWS_PER_APP
        app2: MAX_IMMEDIATE_VIEWS_PER_APP + 3

      @scheduler._tryImmediateView()
        .catch ->
          expect(render).to.not.have.been.called
          done()

    it 'should not render a duplicate view', (done) ->
      render = sinon.spy @scheduler, '_render'
      @scheduler._immediateViewQueues =
        app1: [{viewId: 'view-id', contentId: 'content-id'}]
      @scheduler._consecutiveImmediateRenders =
        app1: 0
      @scheduler._currentApp = 'app1'
      @scheduler._currentView = {viewId: 'other', contentId: 'content-id'}
      @scheduler._tryImmediateView()
        .catch ->
          expect(render).to.not.have.been.called
          done()

    it 'should render when content id is empty', (done) ->
      render = sinon.stub @scheduler, '_render', ->
        promise.reject()
      @scheduler._immediateViewQueues =
        app1: [{viewId: 'view-id'}]
      @scheduler._consecutiveImmediateRenders =
        app1: 0
      @scheduler._currentApp = 'app2'
      @scheduler._currentView = {viewId: 'other'}
      @scheduler._tryImmediateView()
        .catch =>
          expect(@scheduler._immediateViewQueues).to.deep.equal
            app1: []
          expect(@scheduler._consecutiveImmediateRenders).to.deep.equal
            app1: 0
          expect(render).to.have.been.calledOnce
          expect(render.args[0][0]).to.equal 'app1'
          expect(render.args[0][1]).to.deep.equal
            viewId: 'view-id'
          done()

    it 'should fail when render fails', (done) ->
      render = sinon.stub @scheduler, '_render', ->
        promise.reject()
      @scheduler._immediateViewQueues =
        app1: [{viewId: 'view-id', contentId: 'content-id'}]
      @scheduler._consecutiveImmediateRenders =
        app1: 0
      @scheduler._currentApp = 'app2'
      @scheduler._currentView = {viewId: 'other', contentId: 'content-id'}
      @scheduler._tryImmediateView()
        .catch =>
          expect(@scheduler._immediateViewQueues).to.deep.equal
            app1: []
          expect(@scheduler._consecutiveImmediateRenders).to.deep.equal
            app1: 0
          expect(render).to.have.been.calledOnce
          expect(render.args[0][0]).to.equal 'app1'
          expect(render.args[0][1]).to.deep.equal
            viewId: 'view-id'
            contentId: 'content-id'
          done()

    it 'should succeed when render succeeds', (done) ->
      render = sinon.stub @scheduler, '_render', ->
        promise.resolve()
      @scheduler._immediateViewQueues =
        app1: [{viewId: 'view-id', contentId: 'content-id'}]
      @scheduler._consecutiveImmediateRenders =
        app1: 0
      @scheduler._tryImmediateView()
        .then =>
          expect(@scheduler._immediateViewQueues).to.deep.equal
            app1: []
          expect(@scheduler._consecutiveImmediateRenders).to.deep.equal
            app1: 1
          expect(render).to.have.been.calledOnce
          expect(render.args[0][0]).to.equal 'app1'
          expect(render.args[0][1]).to.deep.equal
            viewId: 'view-id'
            contentId: 'content-id'
          done()

  describe '#_tryPriority', ->
    it 'should fail when strategy is invalid', (done) ->
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority 0, 0
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should fail when priority index is negative', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority -1, 0
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should fail when priority index is out of range', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority 10, 0
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should fail when app index is negative', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority 0, -1
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should fail when app index is out of range', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      @scheduler._tryPriority 0, 10
        .catch ->
          expect(tp).to.have.been.calledOnce
          done()

    it 'should succeed when _tryPriorityApp succeeds', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      tpa = sinon.stub @scheduler, '_tryPriorityApp', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._tryPriority 0, 0
        .then ->
          expect(tp).to.have.been.calledOnce
          expect(tpa).to.have.been.calledOnce
          expect(tpa).to.have.been.calledWith ['a', 'b'], 0
          done()

    it 'should try the next app within the same priority when _tryPriorityApp \
        fails', (done) ->
      @scheduler._strategy = [
        ['a', 'b'],
        ['c']
      ]
      tp = sinon.spy @scheduler, '_tryPriority'
      tpa = sinon.stub @scheduler, '_tryPriorityApp', ->
        new promise (resolve, reject) -> reject()
      @scheduler._tryPriority 0, 0
        .catch ->
          expect(tp).to.have.been.calledThrice
          expect(tp.args[0]).to.deep.equal [0, 0]
          expect(tp.args[1]).to.deep.equal [0, 1]
          expect(tp.args[2]).to.deep.equal [0, 2]
          expect(tpa).to.have.been.calledTwice
          expect(tpa.args[0]).to.deep.equal [['a', 'b'], 0]
          expect(tpa.args[1]).to.deep.equal [['a', 'b'], 1]
          done()

  describe '#_tryPriorityApp', ->
    it 'should fail when priority is invalid', (done) ->
      @scheduler._tryPriorityApp undefined, 0
        .catch done

    it 'should fail when app index is negative', (done) ->
      @scheduler._tryPriorityApp ['a'], -3
        .catch done

    it 'should fail when app index is out of range', (done) ->
      @scheduler._tryPriorityApp ['a'], 3
        .catch done

    it 'should fail when tryApp fails', (done) ->
      ta = sinon.stub @scheduler, '_tryApp', ->
        new promise (resolve, reject) -> reject()
      @scheduler._tryPriorityApp ['a'], 0
        .catch ->
          expect(ta).to.have.been.calledOnce
          expect(ta).to.have.been.calledWith 'a'
          done()

    it 'should succeed when tryApp succeeds', (done) ->
      ta = sinon.stub @scheduler, '_tryApp', ->
        new promise (resolve, reject) -> resolve()
      @scheduler._tryPriorityApp ['a', 'b', 'c'], 1
        .then ->
          expect(ta).to.have.been.calledOnce
          expect(ta).to.have.been.calledWith 'b'
          done()

  describe '#_tryApp', ->
    it 'should fail when queue is not okay', (done) ->
      expect(@scheduler._queues).to.deep.equal {}
      @scheduler._tryApp 'app'
        .catch done

    it 'should fail when app is unknown', (done) ->
      @scheduler._queues =
        'app':
          __default: []
      @scheduler._tryApp 'unknown'
        .catch done

    it 'should fail when app queues are empty', (done) ->
      @scheduler._queues =
        'app':
          __default: []
          other: []
      @scheduler._tryApp 'app'
        .catch done

    it 'should try to find a view', (done) ->
      fv = sinon.stub @scheduler, '_findView', -> undefined
      render = sinon.stub @scheduler, '_render', ->
        new promise (resolve, reject) -> resolve()
      view =
        viewId: 'viewId'
        contentId: 'other'
      @scheduler._queues =
        'app':
          __default: []
          other: [view]
      expect(@scheduler._appViewIndex).to.deep.equal {}
      @scheduler._tryApp 'app'
        .catch =>
          expect(@scheduler._appViewIndex.app).to.equal 0
          expect(fv).to.have.been.calledOnce
          expect(fv).to.have.been.calledWith(
            'app', @scheduler._queues.app, ['__default', 'other'], 1)
          expect(render).to.not.have.been.called
          done()

    it 'should render a view', (done) ->
      render = sinon.stub @scheduler, '_render', ->
        new promise (resolve, reject) -> resolve()
      view =
        viewId: 'viewId'
        contentId: 'other'
      @scheduler._queues =
        'app':
          __default: []
          other: [view]
      @scheduler._tryApp 'app'
        .then =>
          expect(@scheduler._queues.app.other).to.deep.equal []
          expect(render).to.have.been.calledOnce
          expect(render).to.have.been.calledWith 'app', view
          done()

    it 'should fail when render fails', (done) ->
      render = sinon.stub @scheduler, '_render', ->
        new promise (resolve, reject) -> reject()
      view =
        viewId: 'viewId'
        contentId: 'other'
      @scheduler._queues =
        'app':
          __default: []
          other: [view]
      @scheduler._tryApp 'app'
        .catch =>
          expect(@scheduler._queues.app.other).to.deep.equal []
          expect(render).to.have.been.calledOnce
          expect(render).to.have.been.calledWith 'app', view
          done()

  describe '#_findView', ->
    it 'should return when asked index is the last rendered one', ->
      fv = sinon.spy @scheduler, '_findView'
      @scheduler._appViewIndex['app'] = 1
      queue =
        __default: []
        first: []
        second: []
      ret = @scheduler._findView 'app', queue, Object.keys(queue), 1
      expect(ret).to.be.undefined
      expect(@scheduler._appViewIndex.app).to.equal 1
      expect(fv).to.have.been.calledOnce

    it 'should advance to the next view queue until it finds one', ->
      fv = sinon.spy @scheduler, '_findView'
      @scheduler._appViewIndex['app'] = 0
      queue =
        __default:  []
        first:      []
        second:     []
        third:      ['v1', 'v2']
        fourth:     ['v3']
      ret = @scheduler._findView 'app', queue, Object.keys(queue), 1
      expect(ret).to.equal 'v1'
      expect(@scheduler._appViewIndex.app).to.equal 3
      expect(fv).to.have.been.calledThrice
      expect(queue).to.deep.equal
        __default:  []
        first:      []
        second:     []
        third:      ['v2']
        fourth:     ['v3']
      expect(fv.args[0]).to.deep.equal ['app', queue, Object.keys(queue), 1]
      expect(fv.args[1]).to.deep.equal ['app', queue, Object.keys(queue), 2]
      expect(fv.args[2]).to.deep.equal ['app', queue, Object.keys(queue), 3]

    it 'should return a view when app has only one queue', ->
      fv = sinon.spy @scheduler, '_findView'
      @scheduler._appViewIndex['app'] = 0
      @scheduler._currentApp = 'app'
      queue =
        __default:  ['v1', 'v2']
      ret = @scheduler._findView 'app', queue, Object.keys(queue), 1
      expect(ret).to.equal 'v1'
      expect(@scheduler._appViewIndex.app).to.equal 0
      expect(fv).to.have.been.calledOnce
      expect(queue).to.deep.equal
        __default:  ['v2']
      expect(fv.args[0]).to.deep.equal ['app', queue, Object.keys(queue), 1]

    it 'should return a view when app has more than one queue but different \
        than the previous app', ->
      fv = sinon.spy @scheduler, '_findView'
      @scheduler._appViewIndex['app'] = 0
      @scheduler._currentApp = 'another-app'
      queue =
        __default:  ['v1', 'v2']
        first: ['v3', 'v4']
      ret = @scheduler._findView 'app', queue, Object.keys(queue), 1
      expect(ret).to.equal 'v3'
      expect(@scheduler._appViewIndex.app).to.equal 1
      expect(fv).to.have.been.calledOnce
      expect(queue).to.deep.equal
        __default:  ['v1', 'v2']
        first: ['v4']
      expect(fv.args[0]).to.deep.equal ['app', queue, Object.keys(queue), 1]

    it 'should return a unique view when the app is the same as currently \
        rendered one and current view is not set', ->
      fv = sinon.spy @scheduler, '_findView'
      @scheduler._appViewIndex['app'] = 0
      @scheduler._currentApp = 'app'
      @scheduler._currentView = undefined
      queue =
        __default: [{contentId: 'v1'}, {contentId: 'v2'}]
        first: [{contentId: 'v3'}, {contentId: 'v4'}]
      ret = @scheduler._findView 'app', queue, Object.keys(queue), 1
      expect(ret).to.deep.equal contentId: 'v3'
      expect(@scheduler._appViewIndex.app).to.equal 1
      expect(fv).to.have.been.calledOnce
      expect(queue).to.deep.equal
        __default: [{contentId: 'v1'}, {contentId: 'v2'}]
        first: [{contentId: 'v4'}]
      expect(fv.args[0]).to.deep.equal ['app', queue, Object.keys(queue), 1]

    it 'should return a unique view when the app is the same as currently \
        rendered one and current view has a differend id', ->
      fv = sinon.spy @scheduler, '_findView'
      @scheduler._appViewIndex['app'] = 0
      @scheduler._currentApp = 'app'
      @scheduler._currentView = contentId: 'other'
      queue =
        __default: [{contentId: 'v1'}, {contentId: 'v2'}]
        first: [{contentId: 'v3'}, {contentId: 'v4'}]
      ret = @scheduler._findView 'app', queue, Object.keys(queue), 1
      expect(ret).to.deep.equal contentId: 'v3'
      expect(@scheduler._appViewIndex.app).to.equal 1
      expect(fv).to.have.been.calledOnce
      expect(queue).to.deep.equal
        __default: [{contentId: 'v1'}, {contentId: 'v2'}]
        first: [{contentId: 'v4'}]
      expect(fv.args[0]).to.deep.equal ['app', queue, Object.keys(queue), 1]

    it 'should skip to the next view if the current one is not unique', ->
      fv = sinon.spy @scheduler, '_findView'
      @scheduler._appViewIndex['app'] = 0
      @scheduler._currentApp = 'app'
      @scheduler._currentView = contentId: 'v3'
      queue =
        __default: [{contentId: 'v1'}, {contentId: 'v2'}]
        first: [{contentId: 'v3'}, {contentId: 'v4'}, {contentId: 'v5'}]
      ret = @scheduler._findView 'app', queue, Object.keys(queue), 1
      expect(ret).to.deep.equal contentId: 'v4'
      expect(@scheduler._appViewIndex.app).to.equal 1
      expect(fv).to.have.been.calledOnce
      expect(queue).to.deep.equal
        __default: [{contentId: 'v1'}, {contentId: 'v2'}]
        first: [{contentId: 'v3'}, {contentId: 'v5'}]
      expect(fv.args[0]).to.deep.equal ['app', queue, Object.keys(queue), 1]

    it 'should check other queues if current queue doesnt have a unique \
        view', ->
      fv = sinon.spy @scheduler, '_findView'
      @scheduler._appViewIndex['app'] = 0
      @scheduler._currentApp = 'app'
      @scheduler._currentView = contentId: 'v3'
      queue =
        __default: [{contentId: 'v1'}, {contentId: 'v2'}]
        first: [{contentId: 'v3'}]
      ret = @scheduler._findView 'app', queue, Object.keys(queue), 1
      expect(ret).to.deep.equal contentId: 'v1'
      expect(@scheduler._appViewIndex.app).to.equal 0
      expect(fv).to.have.been.calledTwice
      expect(queue).to.deep.equal
        __default: [{contentId: 'v2'}]
        first: [{contentId: 'v3'}]
      expect(fv.args[0]).to.deep.equal ['app', queue, Object.keys(queue), 1]
      expect(fv.args[1]).to.deep.equal ['app', queue, Object.keys(queue), 2]

  describe '#_render', ->
    it 'should make a hideRenderShow and render call', (done) ->
      @scheduler._currentApp = 'app2'
      @hideRenderShow.returns new promise (resolve, reject) -> resolve()
      view =
        viewId: 'view-id'
        contentLabel: 'label'
      @scheduler._render 'app1', view
        .then =>
          expect(@hideRenderShow).to.have.been.calledOnce
          expect(@hideRenderShow).to.have.been.calledWith(
            'app2', 'view-id', 'app1')
          expect(@trackView).to.have.been.calledOnce
          expect(@trackView).to.have.been.calledWith 'app1', 'label'
          expect(@scheduler._currentApp).to.equal 'app1'
          expect(@scheduler._currentView).to.deep.equal view
          done()

    it 'should set the current app when hideRenderShow succeeds', (done) ->
      @scheduler._currentApp = 'app2'
      @hideRenderShow.returns new promise (resolve, reject) -> resolve()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .then =>
          expect(@hideRenderShow).to.have.been.calledOnce
          expect(@hideRenderShow).to.have.been.calledWith(
            'app2', 'view-id', 'app1')
          expect(@scheduler._currentApp).to.equal 'app1'
          expect(@scheduler._currentView).to.deep.equal view
          done()

    it 'should fail when hideRenderShow fails', (done) ->
      @scheduler._currentApp = 'app2'
      @scheduler._currentView =
        id: 'old-view'
      @hideRenderShow.returns new promise (resolve, reject) -> reject()
      view =
        viewId: 'view-id'
      @scheduler._render 'app1', view
        .catch =>
          expect(@hideRenderShow).to.have.been.calledOnce
          expect(@hideRenderShow).to.have.been.calledWith(
            'app2', 'view-id', 'app1')
          expect(@scheduler._currentApp).to.equal 'app2'
          expect(@scheduler._currentView).to.deep.equal id: 'old-view'
          done()

  describe '#_prepareApps', ->
    it 'should call prepare() bufferedViewsPerApp times for each app', ->
      prepare = sinon.stub @scheduler, '_prepare'
      @scheduler._apps =
        app1: true
        app2: true
        app3: true
      @scheduler._activePrepareCalls =
        app1: 0
        app2: 0
        app3: 0

      @scheduler._prepareApps()
      expect(prepare).to.have.callCount 3 * @bufferedViewsPerApp

    it 'should make less prepare() calls when there are active calls', ->
      prepare = sinon.stub @scheduler, '_prepare'
      @scheduler._apps =
        app1: true
        app2: true
        app3: true
      @scheduler._activePrepareCalls =
        app1: 0
        app2: 1
        app3: 5

      @scheduler._prepareApps()
      # bufferedViewsPerApp x app1, 1x app2
      expect(prepare).to.have.callCount @bufferedViewsPerApp + 1

    it 'should make less prepare() calls when queues are not empty', ->
      prepare = sinon.stub @scheduler, '_prepare'
      @scheduler._apps =
        app1: true
        app2: true
        app3: true
      @scheduler._activePrepareCalls =
        app1: 0
        app2: 3
        app3: 1
      @scheduler._queues =
        app1:
          __default: ['a', 'b']
        app2:
          __default: ['a']
          __other: ['b']
        app3:
          __default: []
          __other: []

      @scheduler._prepareApps()
      # 1x app3
      expect(prepare).to.have.been.calledOnce
      expect(prepare.args[0][0]).to.equal 'app3'

  describe '#_prepare', ->
    it 'should make a prepare() call', (done) ->
      @prepare.returns new promise (resolve, reject) -> reject()
      @scheduler._activePrepareCalls =
        app: 1
      @scheduler._prepare 'app'
        .catch =>
          expect(@scheduler._activePrepareCalls['app']).to.equal 1
          expect(@prepare).to.have.been.calledOnce
          expect(@prepare).to.have.been.calledWith 'app'
          done()

      expect(@scheduler._activePrepareCalls['app']).to.equal 2

    it "should expire the call when the app doesn't reply back in \
        time", (done) ->
      @prepare.returns new promise (resolve, reject) -> # don't resolve/reject
      @scheduler._activePrepareCalls =
        app: 1
      @scheduler._prepare 'app'
        .catch =>
          expect(@scheduler._activePrepareCalls['app']).to.equal 1
          expect(@prepare).to.have.been.calledOnce
          expect(@prepare).to.have.been.calledWith 'app'
          done()

      expect(@scheduler._activePrepareCalls['app']).to.equal 2
      @clock.tick PREPARE_TIMEOUT

    it 'should add view to the default queue when contentId is \
        empty', (done) ->
      @scheduler._queues =
        app:
          __default: []
      @scheduler._activePrepareCalls =
        app: 1
      @prepare.returns new promise (resolve, reject) ->
        resolve
          viewId: 'view-id'
      @scheduler._prepare 'app'
        .then =>
          expect(@prepare).to.have.been.calledOnce
          expect(@prepare).to.have.been.calledWith 'app'
          expect(@scheduler._queues.app).to.deep.equal
            __default: [
              {
                viewId: 'view-id',
                contentId: '__default',
                contentLabel: undefined
              }
            ]
          done()

    it 'should create a new queue when contentId is not empty', (done) ->
      @scheduler._queues =
        app:
          __default: []
      @scheduler._activePrepareCalls =
        app: 1
      @prepare.returns new promise (resolve, reject) ->
        resolve
          viewId:       'view-id'
          contentId:    'content-id'
          contentLabel: 'label'
      @scheduler._prepare 'app'
        .then =>
          expect(@prepare).to.have.been.calledOnce
          expect(@prepare).to.have.been.calledWith 'app'
          expect(@scheduler._queues.app).to.deep.equal
            __default: []
            'content-id': [
              {
                viewId:       'view-id',
                contentId:    'content-id',
                contentLabel: 'label'
              }
            ]
          done()

  describe '#_initPriorityQueues', ->
    it 'should initialize app queues', ->
      expect(@scheduler._queues).to.deep.equal {}
      @scheduler._apps =
        app1: true
        app2: true
      @scheduler._initPriorityQueues()
      expect(@scheduler._queues).to.deep.equal
        app1:
          __default: []
        app2:
          __default: []
      expect(@scheduler._immediateViewQueues).to.deep.equal
        app1: []
        app2: []
      expect(@scheduler._consecutiveImmediateRenders).to.deep.equal
        app1: 0
        app2: 0
      expect(@scheduler._activePrepareCalls).to.deep.equal
        app1: 0
        app2: 0

  describe '#_extractAppList', ->
    it 'should extract the unique list of apps from a strategy', ->
      strategy = [
        ['app1', 'app2'],
        ['app1', 'app3'],
        ['app4']
      ]
      expect(@scheduler._totalAppSlots).to.equal 0
      ret = @scheduler._extractAppList(strategy)
      expect(ret).to.deep.equal
        app1: true
        app2: true
        app3: true
        app4: true
      expect(@scheduler._totalAppSlots).to.equal 5
      expect(@scheduler._priorityAppIndex).to.deep.equal [0, 0, 0]
