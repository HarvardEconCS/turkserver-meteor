myGroup = "group1"
otherGroup = "group2"
username = "fooser"
treatmentName = "baz"

basicInsertCollection = new Meteor.Collection("basicInsert")
twoGroupCollection = new Meteor.Collection("twoGroup")

###
  Set up server and client hooks
###

if Meteor.isServer
  groupingCollections = {}

  groupingCollections.basicInsert = basicInsertCollection
  groupingCollections.twoGroup = twoGroupCollection

  hookCollection = (collection) ->
    collection._insecure = true

    # Attach the turkserver hooks to the collection
    TurkServer.registerCollection(collection)

if Meteor.isClient
  hookCollection = (collection) -> TurkServer.registerCollection(collection)

###
  Hook collections and run tests
###

hookCollection basicInsertCollection
hookCollection twoGroupCollection

if Meteor.isServer

  # We create the collections in the publisher (instead of using a method or
  # something) because if we made them with a method, we'd need to follow the
  # method with some subscribes, and it's possible that the method call would
  # be delayed by a wait method and the subscribe messages would be sent before
  # it and fail due to the collection not yet existing. So we are very hacky
  # and use a publish.
  Meteor.publish "groupingTests", ->
    return unless @userId

    basicInsertCollection.remove(_direct: true) # Also uses the find feature here
    twoGroupCollection.remove(_direct: true)

    cursors = [ basicInsertCollection.find(), twoGroupCollection.find() ]

    Meteor._debug "grouping publication activated"

    twoGroupCollection.insert
      _direct: true
      _groupId: myGroup
      a: 1

    twoGroupCollection.insert
      _direct: true
      _groupId: otherGroup
      a: 1

    Meteor._debug "collections configured"

    return cursors

  # Insert a fake treatment and experiment
  treatmentId = Treatments.insert
    name: treatmentName

  Experiments.insert
    _id: myGroup
    treatment: treatmentId

  Meteor.methods
    joinGroup: ->
      userId = Meteor.userId()
      throw new Error(403, "Not logged in") unless userId
      TurkServer.Groups.clearUserGroup userId
      TurkServer.Groups.setUserGroup(userId, myGroup)
    serverInsert: (name, doc) ->
      return groupingCollections[name].insert(doc)
    serverUpdate: (name, selector, mutator) ->
      return groupingCollections[name].update(selector, mutator)
    serverRemove: (name, selector) ->
      return groupingCollections[name].remove(selector)
    getCollection: (name, selector) ->
      return groupingCollections[name].find(_.extend(selector || {}, {_direct: true})).fetch()
    getMyCollection: (name, selector) ->
      return groupingCollections[name].find(selector).fetch()
    printCollection: (name) ->
      console.log groupingCollections[name].find(_direct: true).fetch()
    printMyCollection: (name) ->
      console.log groupingCollections[name].find().fetch()

  Tinytest.add "grouping - collections - disallow arbitrary insert", (test) ->
    test.throws ->
      basicInsertCollection.insert {foo: "bar" }
    , (e) -> e.error is 403 and e.reason is ErrMsg.userIdErr

if Meteor.isClient
  ###
    These tests need to all async so they are in the right order
  ###

  # Ensure we are logged in before running these tests
  Tinytest.addAsync "grouping - collections - verify login", (test, next) ->
    InsecureLogin.ready next

  Tinytest.addAsync "grouping - collections - join group", (test, next) ->
    Meteor.call "joinGroup", (err, res) ->
      test.isFalse err
      next()

  # Ensure that the group id has been recorded before subscribing
  Tinytest.addAsync "grouping - collections - received group id", (test, next) ->
    Deps.autorun (c) ->
      groupId = TSConfig.findOne("groupId")
      if groupId?.value
        c.stop()
        test.equal groupId.value, myGroup
        next()

  Tinytest.addAsync "grouping - collections - received experiment id", (test, next) ->
    Deps.autorun (c) ->
      treatment = TSConfig.findOne("treatment")
      if treatment?.value
        c.stop()
        test.equal treatment.value, treatmentName
        next()

  Tinytest.addAsync "grouping - collections - test subscriptions ready", (test, next) ->
    handle = Meteor.subscribe("groupingTests")
    Deps.autorun (c) ->
      if handle.ready()
        c.stop()
        next()

  Tinytest.addAsync "grouping - collections - local empty find", (test, next) ->
    test.equal basicInsertCollection.find().count(), 0
    test.equal basicInsertCollection.find({}).count(), 0
    next()

  Tinytest.addAsync "grouping - collections - remote empty find", (test, next) ->
    Meteor.call "getMyCollection", "basicInsert", {a: 1}, (err, res) ->
      test.isFalse err
      test.equal res.length, 0
      next()

  testAsyncMulti "grouping - collections - basic insert", [
    (test, expect) ->
      id = basicInsertCollection.insert { a: 1 }, expect (err, res) ->
        test.isFalse err, JSON.stringify(err)
        test.equal res, id
  , (test, expect) ->
      test.equal basicInsertCollection.find({a: 1}).count(), 1
      test.equal basicInsertCollection.findOne(a: 1)._groupId, myGroup
  ]

  testAsyncMulti "grouping - collections - find from two groups", [ (test, expect) ->
    test.equal twoGroupCollection.find().count(), 1
    Meteor.call "getCollection", "twoGroup", expect (err, res) ->
      test.isFalse err
      test.equal res.length, 2
  ]

  testAsyncMulti "grouping - collections - insert into two groups", [
    (test, expect) ->
      twoGroupCollection.insert {a: 2}, expect (err) ->
        test.isFalse err, JSON.stringify(err)
        test.equal twoGroupCollection.find().count(), 2
      ###
        twoGroup now contains
        { _groupId: "myGroup", a: 1 }
        { _groupId: "myGroup", a: 2 }
        { _groupId: "otherGroup", a: 1 }
      ###
  , (test, expect) ->
      Meteor.call "getMyCollection", "twoGroup", expect (err, res) ->
        test.isFalse err
        test.equal res.length, 2
  , (test, expect) -> # Ensure that the other half is still on the server
      Meteor.call "getCollection", "twoGroup", expect (err, res) ->
        test.isFalse err, JSON.stringify(err)
        test.equal res.length, 3
  ]

  testAsyncMulti "grouping - collections - server insert for client", [
    (test, expect) ->
      Meteor.call "serverInsert", "twoGroup", {a: 3}, expect (err, res) ->
        test.isFalse err
      ###
        twoGroup now contains
        { _groupId: "myGroup", a: 1 }
        { _groupId: "myGroup", a: 2 }
        { _groupId: "myGroup", a: 3 }
        { _groupId: "otherGroup", a: 1 }
      ###
  , (test, expect) ->
      Meteor.call "getMyCollection", "twoGroup", {}, expect (err, res) ->
        test.isFalse err
        test.equal res.length, 3
  ]

  testAsyncMulti "grouping - collections - server update identical keys across groups", [
    (test, expect) ->
      Meteor.call "serverUpdate", "twoGroup",
        {a: 1},
        $set: { b: 1 }, expect (err, res) ->
          test.isFalse err
      ###
        twoGroup now contains
        { _groupId: "myGroup", a: 1, b: 1 }
        { _groupId: "myGroup", a: 2 }
        { _groupId: "myGroup", a: 3 }
        { _groupId: "otherGroup", a: 1 }
      ###
  , (test, expect) -> # Make sure that the other group's record didn't get updated
      Meteor.call "getCollection", "twoGroup", expect (err, res) ->
        test.isFalse err
        _.each res, (doc) ->
          if doc.a is 1 and doc._groupId is myGroup
            test.equal doc.b, 1
          else
            test.isFalse doc.b
  ]

  testAsyncMulti "grouping - collections - server remove identical keys across groups", [
    (test, expect) ->
      Meteor.call "serverRemove", "twoGroup",
        {a: 1}, expect (err, res) ->
          test.isFalse err
  , (test, expect) -> # Make sure that the other group's record didn't get updated
      Meteor.call "getCollection", "twoGroup", {a: 1}, expect (err, res) ->
        test.isFalse err
        test.equal res.length, 1
        test.equal res[0].a, 1
  ]
