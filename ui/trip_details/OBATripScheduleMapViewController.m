#import "OBATripScheduleMapViewController.h"
#import "OBAStopV2.h"
#import "OBATripStopTimeV2.h"
#import "OBAStopIconFactory.h"
#import "OBATripStopTimeMapAnnotation.h"
#import "OBATripContinuationMapAnnotation.h"
#import "OBACoordinateBounds.h"
#import "OBAStopViewController.h"
#import "OBASphericalGeometryLibrary.h"
#import "OBATripDetailsViewController.h"
#import "OBAAnalytics.h"
#import "UINavigationController+oba_Additions.h"
#import "OBAApplicationDelegate.h"

static const NSString *kTripDetailsContext = @"TripDetails";
static const NSString *kShapeContext = @"ShapeContext";

@interface OBATripScheduleMapViewController ()
@property(nonatomic,strong) NSDateFormatter *timeFormatter;
@property(nonatomic,strong) MKPolyline *routePolyline;
@property(nonatomic,strong) MKPolylineRenderer *routePolylineRenderer;
@property(nonatomic,strong) id<OBAModelServiceRequest> request;
@end

@implementation OBATripScheduleMapViewController

- (void)dealloc {
    [self.request cancel];
    self.request = nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Close", @"") style:UIBarButtonItemStylePlain target:self action:@selector(close:)];

    self.mapView = [[MKMapView alloc] initWithFrame:self.view.bounds];
    self.mapView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    self.mapView.delegate = self;
    [self.view addSubview:self.mapView];

    self.timeFormatter = [[NSDateFormatter alloc] init];
    self.timeFormatter.dateStyle = NSDateFormatterNoStyle;
    self.timeFormatter.timeStyle = NSDateFormatterShortStyle;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    if (self.tripDetails) {
        [self handleTripDetails];
        return;
    }

    [[OBAApplication sharedApplication].modelService requestTripDetailsForTripInstance:self.tripInstance].then(^(OBATripDetailsV2 *tripDetails) {
        self.tripDetails = tripDetails;
        [self handleTripDetails];
    }).catch(^(NSError *error) {
        [self updateProgressViewWithError:error responseCode:error.code];
    });
}

- (void)updateProgressViewWithError:(NSError *)error responseCode:(NSInteger)responseCode {
    if (responseCode == 404) {
        [_progressView setMessage:NSLocalizedString(@"Trip not found", @"message") inProgress:NO progress:0];
    }
    else if (responseCode >= 300) {
        [_progressView setMessage:NSLocalizedString(@"Unknown error", @"message") inProgress:NO progress:0];
    }
    else if (error) {
        OBALogWarningWithError(error, @"Error");
        [_progressView setMessage:NSLocalizedString(@"Error connecting", @"message") inProgress:NO progress:0];
    }
}

#pragma mark - Actions

- (void)close:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - MKMapViewDelegate

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
    if ([annotation isKindOfClass:[OBATripStopTimeMapAnnotation class]]) {
        CGFloat scale = [OBASphericalGeometryLibrary computeStopsForRouteAnnotationScaleFactor:mapView.region];
        CGFloat alpha = scale <= 0.11f ? 0.0f : 1.0f;

        OBATripStopTimeMapAnnotation *an = (OBATripStopTimeMapAnnotation *)annotation;
        static NSString *viewId = @"StopView";

        MKAnnotationView *view = [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];

        if (!view) {
            view = [[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId];
        }

        view.canShowCallout = YES;
        view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        view.image = [OBAStopIconFactory getIconForStop:an.stopTime.stop];
        view.transform = CGAffineTransformMakeScale(scale, scale);
        view.alpha = alpha;
        return view;
    }
    else if ([annotation isKindOfClass:[OBATripContinuationMapAnnotation class]]) {
        static NSString *viewId = @"TripContinutationView";

        MKPinAnnotationView *view = (MKPinAnnotationView *)[mapView dequeueReusableAnnotationViewWithIdentifier:viewId];

        if (view == nil) {
            view = [[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId];
        }

        view.canShowCallout = YES;
        view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        return view;
    }

    return nil;
}

- (void)mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view calloutAccessoryControlTapped:(UIControl *)control {
    id annotation = view.annotation;

    if ([annotation isKindOfClass:[OBATripStopTimeMapAnnotation class] ]) {
        OBATripStopTimeMapAnnotation *an = (OBATripStopTimeMapAnnotation *)annotation;
        OBATripStopTimeV2 *stopTime = an.stopTime;
        UIViewController *vc = [OBAStopViewController stopControllerWithStopID:stopTime.stopId];
        [self.navigationController pushViewController:vc animated:YES];
    }
    else if ([annotation isKindOfClass:[OBATripContinuationMapAnnotation class]]) {
        OBATripContinuationMapAnnotation *an = (OBATripContinuationMapAnnotation *)annotation;
        OBATripDetailsViewController *vc = [[OBATripDetailsViewController alloc] initWithTripInstance:an.tripInstance];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (MKOverlayRenderer *)mapView:(MKMapView *)mapView rendererForOverlay:(id<MKOverlay>)overlay {
    if (overlay == self.routePolyline) {
        if (!self.routePolylineRenderer) {
            self.routePolylineRenderer = [[MKPolylineRenderer alloc] initWithPolyline:self.routePolyline];
            self.routePolylineRenderer.fillColor = [UIColor blackColor];
            self.routePolylineRenderer.strokeColor = [UIColor blackColor];
            self.routePolylineRenderer.lineWidth = 5;
        }

        return self.routePolylineRenderer;
    }
    else {
        return nil;
    }
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {
    CGFloat scale = [OBASphericalGeometryLibrary computeStopsForRouteAnnotationScaleFactor:mapView.region];
    CGFloat alpha = scale <= 0.11f ? 0.f : 1.f;

    NSLog(@"scale=%f alpha=%f", scale, alpha);

    CGAffineTransform transform = CGAffineTransformMakeScale(scale, scale);

    for (id<MKAnnotation> annotation in mapView.annotations) {
        if ([annotation isKindOfClass:[OBATripStopTimeMapAnnotation class]]) {
            MKAnnotationView *view = [mapView viewForAnnotation:annotation];
            view.transform = transform;
            view.alpha = alpha;
        }
    }
}

- (void)handleTripDetails {
    [_progressView setMessage:NSLocalizedString(@"Route Map", @"message") inProgress:NO progress:0];

    OBATripScheduleV2 *sched = _tripDetails.schedule;
    NSArray *stopTimes = sched.stopTimes;
    MKMapView *mapView = [self mapView];

    NSMutableArray *annotations = [[NSMutableArray alloc] init];

    OBACoordinateBounds *bounds = [[OBACoordinateBounds alloc] init];

    for (OBATripStopTimeV2 *stopTime in stopTimes) {
        OBATripStopTimeMapAnnotation *an = [[OBATripStopTimeMapAnnotation alloc] initWithTripDetails:self.tripDetails stopTime:stopTime];
        an.timeFormatter = _timeFormatter;
        [annotations addObject:an];

        OBAStopV2 *stop = stopTime.stop;
        [bounds addLat:stop.lat lon:stop.lon];
    }

    if (sched.nextTripId && stopTimes.count > 0) {
        id<MKAnnotation> an = [self createTripContinuationAnnotation:sched.nextTrip isNextTrip:YES stopTimes:stopTimes];
        [annotations addObject:an];
    }

    if (sched.previousTripId && stopTimes.count > 0) {
        id<MKAnnotation> an = [self createTripContinuationAnnotation:sched.previousTrip isNextTrip:NO stopTimes:stopTimes];
        [annotations addObject:an];
    }

    [mapView addAnnotations:annotations];

    if (!bounds.empty) {
        [mapView setRegion:bounds.region];
    }

    OBATripV2 *trip = _tripDetails.trip;

    if (trip.shapeId) {
        @weakify(self);
        _request = [[OBAApplication sharedApplication].modelService requestShapeForId:trip.shapeId completionBlock:^(id responseData, NSUInteger responseCode, NSError *error) {

            @strongify(self);

            if (responseData) {
                NSString *polylineString = responseData;
                self.routePolyline = [OBASphericalGeometryLibrary decodePolylineStringAsMKPolyline:polylineString];
                [self.mapView addOverlay:self.routePolyline];
            }

            [self.progressView setMessage:NSLocalizedString(@"Route Map", @"message") inProgress:NO progress:0];
        }];
    }
}

- (id<MKAnnotation>)createTripContinuationAnnotation:(OBATripV2 *)trip isNextTrip:(BOOL)isNextTrip stopTimes:(NSArray *)stopTimes {
    OBATripInstanceRef *tripRef = [_tripDetails.tripInstance copyWithNewTripId:trip.tripId];

    NSString *format = isNextTrip ? NSLocalizedString(@"Continues as", @"text") : NSLocalizedString(@"Starts as", @"text");
    NSString *tripTitle = [NSString stringWithFormat:@"%@ %@", format, trip.asLabel];
    NSInteger index = isNextTrip ? ([stopTimes count] - 1) : 0;
    OBATripStopTimeV2 *stopTime = stopTimes[index];
    OBAStopV2 *stop = stopTime.stop;

    MKCoordinateRegion r = [OBASphericalGeometryLibrary createRegionWithCenter:stop.coordinate latRadius:100 lonRadius:100];
    MKCoordinateSpan span = r.span;

    NSInteger x = [self getXOffsetForStop:stop defaultValue:(isNextTrip ? 1 : -1)];
    NSInteger y = [self getYOffsetForStop:stop defaultValue:(isNextTrip ? 1 : -1)];

    double lat = (stop.lat + y * span.latitudeDelta / 2);
    double lon = (stop.lon + x * span.longitudeDelta / 2);
    CLLocationCoordinate2D p = [OBASphericalGeometryLibrary makeCoordinateLat:lat lon:lon];

    return [[OBATripContinuationMapAnnotation alloc] initWithTitle:tripTitle tripInstance:tripRef location:p];
}

- (NSInteger)getXOffsetForStop:(OBAStopV2 *)stop defaultValue:(NSInteger)defaultXOffset {
    NSString *direction = stop.direction;

    if (!direction) return defaultXOffset;

    if ([direction rangeOfString:@"W"].location != NSNotFound) return -1 * defaultXOffset;
    else if ([direction rangeOfString:@"E"].location != NSNotFound) return 1 * defaultXOffset;

    return 0;
}

- (NSInteger)getYOffsetForStop:(OBAStopV2 *)stop defaultValue:(NSInteger)defaultYOffset {
    NSString *direction = stop.direction;

    if (!direction) return defaultYOffset;

    if ([direction rangeOfString:@"S"].location != NSNotFound) return -1 * defaultYOffset;
    else if ([direction rangeOfString:@"N"].location != NSNotFound) return 1 * defaultYOffset;

    return 0;
}

@end
