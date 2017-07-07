/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBWebServer.h"

#import <RoutingHTTPServer/RoutingConnection.h>
#import <RoutingHTTPServer/RoutingHTTPServer.h>

#import "FBCommandHandler.h"
#import "FBErrorBuilder.h"
#import "FBExceptionHandler.h"
#import "FBRouteRequest.h"
#import "FBRuntimeUtils.h"
#import "FBSession.h"
#import "FBUnknownCommands.h"
#import "FBConfiguration.h"
#import "FBLogger.h"

#import "XCUIDevice+FBHelpers.h"
#import "XCAXClient_iOS.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#define BUFFER_SIZE 1024

static NSString *const FBServerURLBeginMarker = @"ServerURLHere->";
static NSString *const FBServerURLEndMarker = @"<-ServerURLHere";
// struct mg_mgr mgr;
// const char *tcp_port = "8200";

int tcp_port = 8200;
int server_fd, client_fd, tcp_err;
struct sockaddr_in server, client;
char buf[BUFFER_SIZE];


@interface FBHTTPConnection : RoutingConnection
@end

@implementation FBHTTPConnection

- (void)handleResourceNotFound
{
  [FBLogger logFmt:@"Received request for %@ which we do not handle", self.requestURI];
  [super handleResourceNotFound];
}

@end


@interface FBWebServer ()
@property (nonatomic, strong) FBExceptionHandler *exceptionHandler;
@property (nonatomic, strong) RoutingHTTPServer *server;
@end

@implementation FBWebServer

+ (NSArray<Class<FBCommandHandler>> *)collectCommandHandlerClasses
{
  NSArray *handlersClasses = FBClassesThatConformsToProtocol(@protocol(FBCommandHandler));
  NSMutableArray *handlers = [NSMutableArray array];
  for (Class aClass in handlersClasses) {
    if ([aClass respondsToSelector:@selector(shouldRegisterAutomatically)]) {
      if (![aClass shouldRegisterAutomatically]) {
        continue;
      }
    }
    [handlers addObject:aClass];
  }
  return handlers.copy;
}

- (void)startServing
{
  [FBLogger logFmt:@"Built at %s %s", __DATE__, __TIME__];
  self.exceptionHandler = [FBExceptionHandler new];
  [self startHTTPServer];
  dispatch_async(dispatch_get_main_queue(),
  ^{
    // mg_mgr_init(&mgr, NULL);
    // mg_bind(&mgr, tcp_port, ev_handler);
    // while (true) {
    //   mg_mgr_poll(&mgr, 1000);
    // }
    // mg_mgr_free(&mgr);
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    // if (server_fd < 0) on_error("Could not create socket\n");

    server.sin_family = AF_INET;
    server.sin_port = htons(tcp_port);
    server.sin_addr.s_addr = htonl(INADDR_ANY);
    int opt_val = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt_val, sizeof opt_val);

    tcp_err = bind(server_fd, (struct sockaddr *) &server, sizeof(server));
    // if (err < 0) on_error("Could not bind socket\n");

    tcp_err = listen(server_fd, 128);
    NSData *screenshot;
    // if (err < 0) on_error("Could not listen on socket\n");
    while (1) {
    socklen_t client_len = sizeof(client);
    client_fd = accept(server_fd, (struct sockaddr *) &client, &client_len);

    // if (client_fd < 0) on_error("Could not establish new connection\n");

    while (1) {
      ssize_t read = recv(client_fd, buf, BUFFER_SIZE, 0);

      if (!read) break; // done reading
      // if (read < 0) on_error("Client read failed\n");
      NSDate *methodStart = [NSDate date];
      screenshot = [[XCAXClient_iOS sharedClient] screenshotData];
      NSDate *methodFinish = [NSDate date];
      NSTimeInterval executionTime = [methodFinish timeIntervalSinceDate:methodStart];
      NSLog(@"Screenshot time = %f", executionTime);

      char start[1] = "b";
      send(client_fd, start, 1, 0);
      unsigned long imgdata_size = screenshot.length;
      NSLog(@"image size %lu", imgdata_size);
      char *imageSizeBuf = (char*) &imgdata_size;
      send(client_fd,imageSizeBuf, sizeof(imgdata_size),0);
      send(client_fd, screenshot.bytes, (int)screenshot.length, 0);   // Echo message back
      NSDate *methodFinish2 = [NSDate date];
      NSTimeInterval executionTime2 = [methodFinish2 timeIntervalSinceDate:methodFinish];
      NSLog(@"TCP Send time = %f", executionTime2);
      // send(client_fd, buf, read, 0);
      // if (err < 0) on_error("Client write failed\n");
    }
  }


  });
  
  [[NSRunLoop mainRunLoop] run];
}

// static void ev_handler(struct mg_connection *nc, int ev, void *p) {
//     struct mbuf *io = &nc->recv_mbuf;
//     (void) p;
//     NSData *screenshot;
//     switch (ev) {
//       case MG_EV_RECV:
//         mbuf_remove(io, io->len);       // Discard message from recv buffer
//       break;
//     }
// }


- (void)startHTTPServer
{
  self.server = [[RoutingHTTPServer alloc] init];
  [self.server setRouteQueue:dispatch_get_main_queue()];
  [self.server setDefaultHeader:@"Server" value:@"WebDriverAgent/1.0"];
  [self.server setConnectionClass:[FBHTTPConnection self]];

  [self registerRouteHandlers:[self.class collectCommandHandlerClasses]];
  [self registerServerKeyRouteHandlers];

  NSRange serverPortRange = FBConfiguration.bindingPortRange;
  NSError *error;
  BOOL serverStarted = NO;

  for (NSUInteger index = 0; index < serverPortRange.length; index++) {
    NSInteger port = serverPortRange.location + index;
    [self.server setPort:(UInt16)port];

    serverStarted = [self attemptToStartServer:self.server onPort:port withError:&error];
    if (serverStarted) {
      break;
    }

    [FBLogger logFmt:@"Failed to start web server on port %ld with error %@", (long)port, [error description]];
  }

  if (!serverStarted) {
    [FBLogger logFmt:@"Last attempt to start web server failed with error %@", [error description]];
    abort();
  }
  [FBLogger logFmt:@"%@http://%@:%d%@", FBServerURLBeginMarker, [XCUIDevice sharedDevice].fb_wifiIPAddress ?: @"localhost", [self.server port], FBServerURLEndMarker];
}

- (BOOL)attemptToStartServer:(RoutingHTTPServer *)server onPort:(NSInteger)port withError:(NSError **)error
{
  server.port = (UInt16)port;
  NSError *innerError = nil;
  BOOL started = [server start:&innerError];
  if (!started) {
    if (!error) {
      return NO;
    }

    NSString *description = @"Unknown Error when Starting server";
    if ([innerError.domain isEqualToString:NSPOSIXErrorDomain] && innerError.code == EADDRINUSE) {
      description = [NSString stringWithFormat:@"Unable to start web server on port %ld", (long)port];
    }
    return
    [[[[FBErrorBuilder builder]
       withDescription:description]
      withInnerError:innerError]
     buildError:error];
  }
  return YES;
}

- (void)registerRouteHandlers:(NSArray *)commandHandlerClasses
{
  for (Class<FBCommandHandler> commandHandler in commandHandlerClasses) {
    NSArray *routes = [commandHandler routes];
    for (FBRoute *route in routes) {
      [self.server handleMethod:route.verb withPath:route.path block:^(RouteRequest *request, RouteResponse *response) {
        NSDictionary *arguments = [NSJSONSerialization JSONObjectWithData:request.body options:NSJSONReadingMutableContainers error:NULL];
        FBRouteRequest *routeParams = [FBRouteRequest
          routeRequestWithURL:request.url
          parameters:request.params
          arguments:arguments ?: @{}
        ];

        [FBLogger verboseLog:routeParams.description];

        @try {
          [route mountRequest:routeParams intoResponse:response];
        }
        @catch (NSException *exception) {
          [self handleException:exception forResponse:response];
        }
      }];
    }
  }
}

- (void)handleException:(NSException *)exception forResponse:(RouteResponse *)response
{
  if ([self.exceptionHandler webServer:self handleException:exception forResponse:response]) {
    return;
  }
  id<FBResponsePayload> payload = FBResponseWithErrorFormat(@"%@\n\n%@", exception.description, exception.callStackSymbols);
  [payload dispatchWithResponse:response];
}

- (void)registerServerKeyRouteHandlers
{
  [self.server get:@"/health" withBlock:^(RouteRequest *request, RouteResponse *response) {
    [response respondWithString:@"I-AM-ALIVE"];
  }];
  [self registerRouteHandlers:@[FBUnknownCommands.class]];
}

@end
