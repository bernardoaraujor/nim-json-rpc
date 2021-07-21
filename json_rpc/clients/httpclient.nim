import
  std/[strutils, tables, uri],
  stew/[byteutils, results],
  chronos/apps/http/httpclient as chronosHttpClient,
  chronicles, httputils, json_serialization/std/net,
  ".."/[client, errors]

export
  client

logScope:
  topics = "JSONRPC-HTTP-CLIENT"

type
  HttpClientOptions* = object
    httpMethod: HttpMethod

  RpcHttpClient* = ref object of RpcClient
    httpSession: HttpSessionRef
    httpAddress: HttpResult[HttpAddress]
    maxBodySize: int

const
  MaxHttpRequestSize = 128 * 1024 * 1024 # maximum size of HTTP body in octets

proc new(T: type RpcHttpClient, maxBodySize = MaxHttpRequestSize): T =
  T(
    maxBodySize: maxBodySize,
    httpSession: HttpSessionRef.new(),
  )

proc newRpcHttpClient*(maxBodySize = MaxHttpRequestSize): RpcHttpClient =
  RpcHttpClient.new(maxBodySize)

method call*(client: RpcHttpClient, name: string,
             params: JsonNode): Future[Response]
            {.async, gcsafe, raises: [Defect, CatchableError].} =
  doAssert client.httpSession != nil
  if client.httpAddress.isErr:
    raise newException(RpcAddressUnresolvableError, client.httpAddress.error)

  let
    id = client.getNextId()
    reqBody = $rpcCallNode(name, params, id)
    req = HttpClientRequestRef.post(client.httpSession,
                                    client.httpAddress.get,
                                    body = reqBody.toOpenArrayByte(0, reqBody.len - 1))
    res =
      try:
        await req.send()
      except CancelledError as exc:
        raise exc
      except HttpError as exc:
        raise exc
      except AsyncStreamError as exc:
        raise exc

  let resStatusStr = $res.status
  if resStatusStr[0] != '2': # res.status is not 2xx (success)
    raise newException(HttpError, "POST Response: " & $res.status)

  debug "Message sent to RPC server",
         address = client.httpAddress, msg_len = len(reqBody)
  trace "Message", msg = reqBody

  let resBytes =
    try:
      await res.getBodyBytes(client.maxBodySize)
    except CancelledError as exc:
      raise exc
    except AsyncStreamError as exc:
      raise exc

  let resText = string.fromBytes(resBytes)
  trace "Response", text = resText

  # completed by processMessage - the flow is quite weird here to accomodate
  # socket and ws clients, but could use a more thorough refactoring
  var newFut = newFuture[Response]()
  # add to awaiting responses
  client.awaiting[id] = newFut

  try:
    # Might raise for all kinds of reasons
    client.processMessage(resText)
  finally:
    # Need to clean up in case the answer was invalid
    client.awaiting.del(id)

  # processMessage should have completed this future - if it didn't, `read` will
  # raise, which is reasonable
  if newFut.finished:
    return newFut.read()
  else:
    # TODO: Provide more clarity regarding the failure here
    raise newException(InvalidResponse, "Invalid response")

proc connect*(client: RpcHttpClient, url: string)
             {.async, raises: [Defect].} =
  client.httpAddress = client.httpSession.getAddress(url)
  if client.httpAddress.isErr:
    raise newException(RpcAddressUnresolvableError, client.httpAddress.error)

proc connect*(client: RpcHttpClient, address: string, port: Port) {.async.} =
  let url = "http://" & address & ":" & $port
  client.httpAddress = client.httpSession.getAddress(url)
  if client.httpAddress.isErr:
    raise newException(RpcAddressUnresolvableError, client.httpAddress.error)