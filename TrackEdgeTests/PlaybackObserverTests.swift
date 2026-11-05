import XCTest
@testable import TrackEdge

@MainActor
final class PlaybackObserverTests: XCTestCase {
    private func post(_ name: String, state: String, on center: NotificationCenter, extra: [String: String] = [:]) {
        var info = extra
        info["Player State"] = state
        center.post(name: Notification.Name(name), object: nil, userInfo: info)
    }

    func testReportsPausedFromSpotify() {
        let center = NotificationCenter()
        let observer = PlaybackObserver(center: center)
        let done = expectation(description: "event")
        observer.waitForChange(after: Date(), timeout: 2) { event in
            XCTAssertEqual(event?.app, "Spotify")
            XCTAssertEqual(event?.state, .paused)
            done.fulfill()
        }
        post("com.spotify.client.PlaybackStateChanged", state: "Paused", on: center)
        wait(for: [done], timeout: 3)
    }

    func testReportsPlayingFromMusic() {
        let center = NotificationCenter()
        let observer = PlaybackObserver(center: center)
        let done = expectation(description: "event")
        observer.waitForChange(after: Date(), timeout: 2) { event in
            XCTAssertEqual(event?.app, "Music")
            XCTAssertEqual(event?.state, .playing)
            done.fulfill()
        }
        post("com.apple.Music.playerInfo", state: "Playing", on: center)
        wait(for: [done], timeout: 3)
    }

    func testCarriesTrackTitleAndArtist() {
        let center = NotificationCenter()
        let observer = PlaybackObserver(center: center)
        let done = expectation(description: "event")
        observer.waitForChange(after: Date(), timeout: 2) { event in
            let e = try! XCTUnwrap(event)
            XCTAssertEqual(e.title, "Song")
            XCTAssertEqual(e.artist, "Artist")
            let skip = MediaHUD.Content(skip: .next, event: e)
            XCTAssertEqual(skip?.title, "Song")
            XCTAssertEqual(skip?.subtitle, "Artist · Spotify")
            XCTAssertEqual(skip?.symbol, "forward.fill")
            XCTAssertNil(MediaHUD.Content(skip: .playPause, event: e))
            XCTAssertEqual(MediaHUD.Content(e).subtitle, "Song · Spotify")
            done.fulfill()
        }
        post("com.spotify.client.PlaybackStateChanged", state: "Playing", on: center,
             extra: ["Name": "Song", "Artist": "Artist", "Album": "Album"])
        wait(for: [done], timeout: 3)
    }

    func testSkipWithoutTrackInfoKeepsGenericLabel() {
        let event = PlaybackObserver.Event(app: "Music", state: .playing, title: nil, artist: nil, date: Date())
        XCTAssertNil(MediaHUD.Content(skip: .previous, event: event))
    }

    func testTimesOutWhenNoPlayerReports() {
        let observer = PlaybackObserver(center: NotificationCenter())
        let done = expectation(description: "timeout")
        observer.waitForChange(after: Date(), timeout: 0.2) { event in
            XCTAssertNil(event, "unknown players fall back to the neutral label")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testIgnoresEventsFromBeforeTheCommand() {
        let center = NotificationCenter()
        let observer = PlaybackObserver(center: center)
        post("com.spotify.client.PlaybackStateChanged", state: "Playing", on: center)
        let done = expectation(description: "timeout")
        observer.waitForChange(after: Date().addingTimeInterval(1), timeout: 0.2) { event in
            XCTAssertNil(event, "a stale broadcast must not be reported as the result")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
