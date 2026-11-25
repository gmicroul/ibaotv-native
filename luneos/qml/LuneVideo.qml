import QtQuick
import QtMultimedia

Item {
    id: root
    property bool autoLoad: true
    property bool autoPlay: true
    property alias source: player.source
    property alias status: player.mediaStatus
    property alias playbackState: player.playbackState
    property alias playbackRate: player.playbackRate
    property alias position: player.position
    property alias duration: player.duration
    property alias seekable: player.seekable
    property alias error: player.error
    property alias errorString: player.errorString
    property alias fillMode: output.fillMode

    function play() {
        if (source.toString() !== "")
            player.play()
    }
    function pause() { player.pause() }
    function stop() { player.stop() }
    function seek(milliseconds) { player.position = Math.round(milliseconds) }

    AudioOutput {
        id: sound
        volume: 1.0
    }
    MediaPlayer {
        id: player
        objectName: "ibaotvMediaPlayer"
        audioOutput: sound
        videoOutput: output
        onSourceChanged: {
            if (root.autoPlay)
                Qt.callLater(root.play)
        }
    }
    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
    }
}
