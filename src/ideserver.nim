## Loopback-only, bounded nonblocking WebSocket transport. No editor dependencies.
import std/[asyncdispatch, asyncnet, net, os, sysrand, strutils, json, times]
import ideprotocol
when not defined(windows): import std/posix

type
  IdePeer* = ref object
    socket: AsyncSocket
    ready*, closed*: bool
    output: string
    sending: bool
    started, sendingAt: float
  IdeServer* = ref object
    socket: AsyncSocket
    port*: int
    token*, root*, lockPath*: string
    peers*: seq[IdePeer]
    closed: bool
    lockId: tuple[device: DeviceId, file: FileId]
    onMessage*: proc(peer: IdePeer, text: string) {.closure.}
    onClose*: proc(peer: IdePeer) {.closure.}

proc close*(peer: IdePeer) =
  if peer.closed: return
  peer.closed = true
  peer.ready = false
  if peer.socket != nil: peer.socket.close()
  peer.output = ""

proc flush(peer: IdePeer) {.async.} =
  peer.sending = true
  peer.sendingAt = epochTime()
  try:
    while not peer.closed and peer.output.len > 0:
      let wire = move(peer.output)
      await peer.socket.send(wire)
      peer.sendingAt = epochTime()
  except CatchableError: peer.close()
  finally: peer.sending = false

proc queue(peer: IdePeer, wire: string) =
  if peer.closed: return
  if peer.output.len + wire.len > maxIdeMessage * 2:
    peer.close()
    return
  peer.output.add wire
  if peer.socket != nil and not peer.sending: asyncCheck peer.flush()

proc send*(peer: IdePeer, value: JsonNode) =
  if peer.ready and value != nil: peer.queue(wsFrame($value))

proc takeOutput*(peer: IdePeer): string =
  ## Drain queued wire bytes for an in-memory transport (also used by headless tests).
  result = move(peer.output)

proc serve(server: IdeServer, peer: IdePeer) {.async.} =
  var input = ""
  var decoder: WsDecoder
  try:
    while not peer.closed:
      let chunk = await peer.socket.recv(16384)
      if chunk.len == 0: break
      input.add chunk
      if not peer.ready:
        let endAt = input.find("\r\n\r\n")
        if endAt < 0:
          if input.len > 16384: break
          continue
        if endAt > 16384: break
        let response = handshake(input[0..<endAt+4], server.token)
        await peer.socket.send(response)
        if not response.startsWith("HTTP/1.1 101"): break
        input = input[endAt+4..^1]
        peer.ready = true
      var frame: WsFrame
      while takeFrame(input, frame):
        case frame.opcode
        of 8:
          peer.queue(wsFrame(frame.payload, 8))
          while peer.sending and not peer.closed: await sleepAsync(1)
          return
        of 9: peer.queue(wsFrame(frame.payload, 10))
        of 10: discard
        else:
          let message = decoder.message(frame)
          if frame.final and server.onMessage != nil: server.onMessage(peer, message)
        # Bound callbacks per editor tick even when a client floods tiny frames.
        await sleepAsync(1)
  except ValueError:
    peer.queue(wsFrame("\x03\xea", 8))
    while peer.sending and not peer.closed: await sleepAsync(1)
  except CatchableError: discard
  finally:
    peer.close()
    if server.onClose != nil: server.onClose(peer)

proc acceptPeers(server: IdeServer) {.async.} =
  try:
    while not server.closed:
      let socket = await server.socket.accept()
      if server.closed:
        socket.close()
        break
      if server.peers.len >= 16:
        socket.close()
        continue
      let peer = IdePeer(socket: socket, started: epochTime())
      server.peers.add peer
      asyncCheck server.serve(peer)
  except CatchableError: discard

proc writeLock*(path, contents: string) =
  ## O_EXCL never replaces another IDE's lock or follows a pre-existing symlink.
  when defined(windows):
    raise newException(IOError, "IDE bridge requires Unix lock permissions")
  else:
    let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
    if fd < 0: raiseOSError(osLastError())
    try:
      if fchmod(fd, Mode(0o600)) != 0: raiseOSError(osLastError())
      var at = 0
      while at < contents.len:
        let n = posix.write(fd, unsafeAddr contents[at], contents.len - at)
        if n <= 0: raiseOSError(osLastError())
        at += n
    except CatchableError:
      removeFile(path) # only the file this call created
      raise
    finally: discard posix.close(fd)

proc newAuthToken*(): string =
  var bytes: array[16, byte]
  if not urandom(bytes): raise newException(IOError, "CSPRNG unavailable")
  for b in bytes: result.add toHex(b, 2).toLowerAscii

proc startIdeServer*(root: string): IdeServer =
  result = IdeServer(root: root, token: newAuthToken())
  result.socket = newAsyncSocket(buffered = false)
  try:
    result.socket.bindAddr(Port(0), "127.0.0.1")
    result.socket.listen()
    result.port = int(result.socket.getLocalAddr()[1])
    let directory = getHomeDir() / ".claude" / "ide"
    createDir(directory)
    let path = directory / ($result.port & ".lock")
    writeLock(path, $lockInfo(getCurrentProcessId(), @[root], result.token))
    result.lockPath = path
    result.lockId = getFileInfo(path, followSymlink = false).id
    asyncCheck acceptPeers(result)
  except CatchableError:
    result.socket.close()
    raise

proc stop*(server: IdeServer) =
  if server == nil or server.closed: return
  server.closed = true
  for peer in server.peers:
    peer.close()
  server.peers = @[]
  server.socket.close()
  if server.lockPath.len > 0:
    # Never remove a replacement file belonging to another process.
    try:
      if getFileInfo(server.lockPath, followSymlink = false).id == server.lockId:
        removeFile(server.lockPath)
    except OSError: discard
    server.lockPath = ""

proc pollIdeServer*(server: IdeServer) =
  if server == nil: return
  if hasPendingOperations(): asyncdispatch.poll(0)
  for i in countdown(server.peers.high, 0):
    let peer = server.peers[i]
    if not peer.ready and epochTime() - peer.started > 5: peer.close()
    if peer.sending and epochTime() - peer.sendingAt > 10: peer.close()
    if peer.closed: server.peers.delete(i)

proc connected*(server: IdeServer): bool =
  if server != nil:
    for peer in server.peers:
      if peer.ready: return true

proc broadcast*(server: IdeServer, value: JsonNode) =
  if server != nil:
    for peer in server.peers: peer.send(value)
