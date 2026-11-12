// First Row's media engine for older systems.
//
// The main engine (MediaEngine/Sources) needs macOS 15, iOS 18 or tvOS 18. This one plays the
// further kinds of movie file on the systems before those that First Row still runs on: macOS
// 10.15 to 14, iOS and tvOS 15.6 to 17. It is plainer: FFmpeg reads the file and decodes what
// the system's own decoders can't, and the picture and the sound go out through the system's
// sample-buffer layer and renderer, kept in step by the system's synchronizer. There is no HDR
// here, no Dolby Vision and no shared folders; subtitles, audio tracks, chapters and speed work
// as in the main engine.
//
// It is written in Objective-C so that any Xcode can build it for those systems (see build.sh).
// First Row knows it only as an object of the class FirstRowMediaEngineOlder that answers the
// two protocols in firstrow/Movies.frappliance/MediaEngineInterface.swift, which are declared
// again here as Objective-C sees them: the names and selectors must stay the same in both.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libavutil/avutil.h>
#import <libavutil/channel_layout.h>
#import <libavutil/hwcontext.h>
#import <libavutil/imgutils.h>
#import <libavutil/opt.h>
#import <libswresample/swresample.h>
#import <libswscale/swscale.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - What First Row and the engine say to each other (see MediaEngineInterface.swift)

static NSString *const KeyURL = @"url";
static NSString *const KeyHeaders = @"headers";
static NSString *const KeyStart = @"start";
static NSString *const KeyPaused = @"paused";
static NSString *const KeySubtitleFiles = @"subtitleFiles";
static NSString *const KeyID = @"id";
static NSString *const KeyName = @"name";
static NSString *const KeyLanguage = @"language";
static NSString *const KeyCodec = @"codec";
static NSString *const KeyChannels = @"channels";
static NSString *const KeyIsChosen = @"isChosen";
static NSString *const KeyIsForced = @"isForced";
static NSString *const KeyTitle = @"title";
static NSString *const KeyText = @"text";
static NSString *const KeyImage = @"image";
static NSString *const KeyX = @"x";
static NSString *const KeyY = @"y";
static NSString *const KeyWidth = @"width";
static NSString *const KeyHeight = @"height";
static NSString *const KeyCanvasWidth = @"canvasWidth";
static NSString *const KeyCanvasHeight = @"canvasHeight";
static NSString *const KeyDuration = @"duration";
static NSString *const KeyHasVideo = @"hasVideo";
static NSString *const KeyArtwork = @"artwork";
static NSString *const KeyError = @"error";
static NSString *const KeySeconds = @"seconds";
static NSString *const KeyLongestSide = @"longestSide";

static const NSInteger InterfaceVersion = 3;

@protocol FirstRowMediaEnginePlaying <NSObject>
@property (nonatomic, readonly) CALayer *pictureLayer;
@property (nonatomic, copy, nullable) void (^onChange)(void);
- (void)open:(NSDictionary<NSString *, id> *)request;
- (void)close;
- (void)play;
- (void)pause;
@property (nonatomic, readonly) NSString *phase;
@property (nonatomic, readonly) BOOL isWaiting;
@property (nonatomic, readonly, nullable) NSString *failure;
@property (nonatomic, readonly) BOOL hasPicture;
@property (nonatomic, readonly) double position;
@property (nonatomic, readonly) double duration;
- (void)seekTo:(double)seconds exactly:(BOOL)exactly then:(void (^_Nullable)(BOOL))done;
@property (nonatomic) double speed;
@property (nonatomic) BOOL isMuted;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *audioTracks;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *subtitleTracks;
- (void)chooseAudioTrack:(NSInteger)identifier;
- (void)chooseSubtitleTrack:(NSInteger)identifier;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *chapters;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *captions;
@property (nonatomic, readonly) NSInteger captionsRevision;
@property (nonatomic, readonly) NSString *pictureKind;
@property (nonatomic, readonly) CGSize pictureSize;
@property (nonatomic, readonly, nullable) AVPlayer *systemPlayer;
@property (nonatomic) BOOL keepsPictureInPictureReady;
@property (nonatomic, readonly) BOOL isInPictureInPicture;
- (void)leavePictureInPicture;
@end

@protocol FirstRowMediaEngineProviding <NSObject>
@property (nonatomic, readonly) NSInteger interfaceVersion;
@property (nonatomic, readonly) NSString *engineDescription;
- (nullable NSObject *)player;
- (void)describe:(NSURL *)url then:(void (^)(NSDictionary<NSString *, id> *))answer;
- (void)pictureOf:(NSURL *)url details:(NSDictionary<NSString *, id> *)details then:(void (^)(CGImageRef _Nullable))answer;
- (void)ask:(NSString *)question details:(NSDictionary<NSString *, id> *)details then:(void (^)(NSDictionary<NSString *, id> *))answer;
@end

// MARK: - Small helpers

static NSString *ErrorText(int code) {
    char text[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, text, sizeof(text));
    return [NSString stringWithUTF8String:text] ?: @"unknown error";
}

static NSString *_Nullable Tag(AVDictionary *_Nullable tags, const char *name) {
    AVDictionaryEntry *entry = av_dict_get(tags, name, NULL, 0);
    if (!entry || !entry->value || !entry->value[0]) return nil;
    return [NSString stringWithUTF8String:entry->value];
}

/// A layer that keeps the layer inside it filling it, whatever size First Row gives it.
@interface FROlderPictureLayer : CALayer
@end

@implementation FROlderPictureLayer
- (void)layoutSublayers {
    [super layoutSublayers];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *layer in self.sublayers) layer.frame = self.bounds;
    [CATransaction commit];
}
@end

/// What mpeg calls a DVD's files: a folder that holds a DVD is opened as its largest title's
/// files joined end to end (they are one stream cut into files of a gigabyte).
static NSString *_Nullable AddressToOpen(NSURL *url) {
    if (!url.isFileURL) return url.absoluteString;
    BOOL isFolder = NO;
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:url.path isDirectory:&isFolder]) return nil;
    if (!isFolder) return url.path;
    for (NSURL *place in @[[url URLByAppendingPathComponent:@"VIDEO_TS"], [url URLByAppendingPathComponent:@"video_ts"], url]) {
        if (![files fileExistsAtPath:[place URLByAppendingPathComponent:@"VIDEO_TS.IFO"].path] &&
            ![files fileExistsAtPath:[place URLByAppendingPathComponent:@"video_ts.ifo"].path]) continue;
        NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *sets = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSNumber *, NSNumber *> *sizes = [NSMutableDictionary dictionary];
        for (NSString *name in [[files contentsOfDirectoryAtPath:place.path error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *upper = name.uppercaseString;
            if (![upper hasPrefix:@"VTS_"] || ![upper hasSuffix:@".VOB"]) continue;
            NSArray<NSString *> *pieces = [[upper stringByDeletingPathExtension] componentsSeparatedByString:@"_"];
            if (pieces.count != 3 || pieces[2].integerValue < 1) continue;
            NSNumber *set = @(pieces[1].integerValue);
            NSString *path = [place URLByAppendingPathComponent:name].path;
            if (!sets[set]) sets[set] = [NSMutableArray array];
            [sets[set] addObject:path];
            unsigned long long size = [[files attributesOfItemAtPath:path error:NULL] fileSize];
            sizes[set] = @(sizes[set].unsignedLongLongValue + size);
        }
        NSNumber *largest = nil;
        for (NSNumber *set in sets) {
            if (!largest || sizes[set].unsignedLongLongValue > sizes[largest].unsignedLongLongValue) largest = set;
        }
        if (!largest) return nil;
        return [@"concat:" stringByAppendingString:[sets[largest] componentsJoinedByString:@"|"]];
    }
    return nil;
}

/// Opens a movie for reading, with what is to be sent with each request for it on a server.
static AVFormatContext *_Nullable OpenMovie(NSURL *url, NSDictionary<NSString *, NSString *> *_Nullable headers, NSString *_Nullable *_Nullable why) {
    NSString *address = AddressToOpen(url);
    if ([url.scheme isEqualToString:@"smb"] || !address) {
        if (why) *why = [url.scheme isEqualToString:@"smb"] ? @"Shared folders need a newer system." : @"First Row couldn't open it.";
        return NULL;
    }
    AVDictionary *options = NULL;
    if (headers.count) {
        NSMutableString *lines = [NSMutableString string];
        for (NSString *name in headers) [lines appendFormat:@"%@: %@\r\n", name, headers[name]];
        av_dict_set(&options, "headers", lines.UTF8String, 0);
    }
    av_dict_set(&options, "reconnect", "1", 0);
    AVFormatContext *format = NULL;
    int result = avformat_open_input(&format, address.UTF8String, NULL, &options);
    av_dict_free(&options);
    if (result < 0) {
        if (why) *why = ErrorText(result);
        return NULL;
    }
    result = avformat_find_stream_info(format, NULL);
    if (result < 0) {
        if (why) *why = ErrorText(result);
        avformat_close_input(&format);
        return NULL;
    }
    return format;
}

/// One subtitle: words, or a picture with its place, shown from `start` until `end`.
@interface FROlderCue : NSObject
@property (nonatomic) NSInteger number;
@property (nonatomic) double start;
@property (nonatomic) double end;
@property (nonatomic, copy, nullable) NSString *text;
@property (nonatomic, strong, nullable) __attribute__((NSObject)) CGImageRef image;
@property (nonatomic) CGRect place;
@property (nonatomic) CGSize canvas;
@end

@implementation FROlderCue
@end

/// The words of a subtitle as FFmpeg hands them on ("0,0,Default,,0,0,0,,{\i1}Words\Nmore"),
/// with the styling taken out.
static NSString *PlainWords(const char *line) {
    NSString *all = [NSString stringWithUTF8String:line] ?: @"";
    NSUInteger commas = 0, at = 0;
    for (; at < all.length && commas < 8; at++) {
        if ([all characterAtIndex:at] == ',') commas++;
    }
    NSMutableString *words = [[all substringFromIndex:commas == 8 ? at : 0] mutableCopy];
    while (YES) {
        NSRange open = [words rangeOfString:@"{"];
        if (open.location == NSNotFound) break;
        NSRange close = [words rangeOfString:@"}" options:0 range:NSMakeRange(open.location, words.length - open.location)];
        if (close.location == NSNotFound) break;
        [words deleteCharactersInRange:NSMakeRange(open.location, NSMaxRange(close) - open.location)];
    }
    [words replaceOccurrencesOfString:@"\\N" withString:@"\n" options:0 range:NSMakeRange(0, words.length)];
    [words replaceOccurrencesOfString:@"\\n" withString:@"\n" options:0 range:NSMakeRange(0, words.length)];
    [words replaceOccurrencesOfString:@"\\h" withString:@" " options:0 range:NSMakeRange(0, words.length)];
    return [words stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

/// A subtitle picture as an image: FFmpeg gives a colour number for each pixel and the colours.
static CGImageRef _Nullable CreateSubtitleImage(const AVSubtitleRect *rect) CF_RETURNS_RETAINED {
    if (rect->w <= 0 || rect->h <= 0 || !rect->data[0] || !rect->data[1]) return NULL;
    size_t width = (size_t)rect->w, height = (size_t)rect->h;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *out = pixels.mutableBytes;
    const uint32_t *colours = (const uint32_t *)rect->data[1];
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = rect->data[0] + y * (size_t)rect->linesize[0];
        for (size_t x = 0; x < width; x++) {
            uint32_t colour = row[x] < rect->nb_colors ? colours[row[x]] : 0;
            uint32_t alpha = colour >> 24;
            // (Kept with the colours already multiplied by how solid they are, as the system wants.)
            *out++ = (uint8_t)((((colour >> 16) & 0xFF) * alpha) / 255);
            *out++ = (uint8_t)((((colour >> 8) & 0xFF) * alpha) / 255);
            *out++ = (uint8_t)(((colour & 0xFF) * alpha) / 255);
            *out++ = (uint8_t)alpha;
        }
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN

// MARK: - The player

static enum AVPixelFormat ChoosePixelFormat(AVCodecContext *context, const enum AVPixelFormat *formats) {
    // The system's own decoder where the codec has one; FFmpeg's otherwise.
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++) {
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
    }
    return formats[0];
}

@interface FROlderPlayer : NSObject <FirstRowMediaEnginePlaying>
@end

@implementation FROlderPlayer {
    FROlderPictureLayer *_picture;
    AVSampleBufferDisplayLayer *_display;
    AVSampleBufferAudioRenderer *_sound;
    AVSampleBufferRenderSynchronizer *_clock;
    dispatch_queue_t _work;

    // Used only on the work queue.
    AVFormatContext *_format;
    AVCodecContext *_videoDecoder;
    AVCodecContext *_audioDecoder;
    AVCodecContext *_subtitleDecoder;
    int _videoStream, _audioStream, _subtitleStream;
    AVBufferRef *_hardware;
    struct SwsContext *_scaler;
    CVPixelBufferPoolRef _pool;
    int _poolWidth, _poolHeight;
    OSType _poolKind;
    SwrContext *_resampler;
    int _resamplerRate, _resamplerFormat, _resamplerChannels;
    CMAudioFormatDescriptionRef _soundFormat;
    int _soundRate;
    AVPacket *_packet;
    AVFrame *_frame;
    double _startOffset;
    double _videoAhead, _audioAhead;
    double _dropBefore;
    BOOL _atEnd, _anchored, _saidEnded;

    // Shared between the main thread and the work queue, under @synchronized (self).
    NSInteger _session;
    NSString *_phase;
    NSString *_failure;
    BOOL _wantsPlay, _hasPicture, _isAnchored, _muted;
    double _duration, _speed, _restingPosition;
    CGSize _pictureSize;
    NSArray<NSDictionary<NSString *, id> *> *_audioTracks, *_subtitleTracks, *_chapters;
    NSMutableArray<FROlderCue *> *_cues;
    NSMutableDictionary<NSNumber *, NSArray<FROlderCue *> *> *_fileCues;
    NSInteger _cueNumber, _chosenSubtitle, _revision;
    NSArray<NSNumber *> *_shownCues;
    NSArray<NSDictionary<NSString *, id> *> *_shownCaptions;
}

@synthesize onChange = _onChange;

- (instancetype)init {
    if ((self = [super init])) {
        _picture = [FROlderPictureLayer layer];
        _picture.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        _picture.masksToBounds = YES;
        _display = [AVSampleBufferDisplayLayer layer];
        _display.videoGravity = AVLayerVideoGravityResizeAspect;
        [_picture addSublayer:_display];
        _sound = [AVSampleBufferAudioRenderer new];
        _clock = [AVSampleBufferRenderSynchronizer new];
        [_clock addRenderer:_display];
        [_clock addRenderer:_sound];
        _work = dispatch_queue_create("firstrow.mediaengine.older", DISPATCH_QUEUE_SERIAL);
        _phase = @"idle";
        _speed = 1;
        _audioTracks = @[];
        _subtitleTracks = @[];
        _chapters = @[];
        _cues = [NSMutableArray array];
        _fileCues = [NSMutableDictionary dictionary];
        _chosenSubtitle = -1;
        _shownCues = @[];
        _shownCaptions = @[];
        _videoStream = _audioStream = _subtitleStream = -1;
    }
    return self;
}

- (CALayer *)pictureLayer { return _picture; }

- (void)changed {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onChange) self.onChange();
    });
}

- (BOOL)isCurrent:(NSInteger)session {
    @synchronized (self) { return session == _session; }
}

// MARK: Opening and letting go

- (void)open:(NSDictionary<NSString *, id> *)request {
    NSInteger session;
    NSURL *url = request[KeyURL];
    NSDictionary<NSString *, NSString *> *headers = request[KeyHeaders];
    double start = [request[KeyStart] doubleValue];
    NSArray<NSDictionary<NSString *, id> *> *files = request[KeySubtitleFiles];
    @synchronized (self) {
        session = ++_session;
        _phase = @"opening";
        _failure = nil;
        _wantsPlay = ![request[KeyPaused] boolValue];
        _hasPicture = NO;
        _isAnchored = NO;
        _duration = 0;
        _restingPosition = MAX(0, start);
        _pictureSize = CGSizeZero;
        _audioTracks = @[];
        _subtitleTracks = @[];
        _chapters = @[];
        [_cues removeAllObjects];
        [_fileCues removeAllObjects];
        _chosenSubtitle = -1;
        _shownCues = @[];
        _shownCaptions = @[];
        _revision += 1;
    }
    dispatch_async(_work, ^{
        [self tearDown];
        if (![self isCurrent:session]) return;
        if (!url) {
            [self failWith:@"First Row couldn't open it." session:session];
            return;
        }
        [self openMovie:url headers:headers start:start subtitleFiles:files session:session];
    });
    [self changed];
}

- (void)close {
    @synchronized (self) {
        _session += 1;
        _phase = @"idle";
        _failure = nil;
        _wantsPlay = NO;
        _hasPicture = NO;
        _isAnchored = NO;
        [_cues removeAllObjects];
        _shownCues = @[];
        _shownCaptions = @[];
        _revision += 1;
    }
    dispatch_async(_work, ^{ [self tearDown]; });
    [self changed];
}

- (void)failWith:(NSString *)why session:(NSInteger)session {
    @synchronized (self) {
        if (session != _session) return;
        _phase = @"failed";
        _failure = why;
    }
    [self changed];
}

/// Lets go of everything FFmpeg holds for the movie, and empties the layer and the sound.
- (void)tearDown {
    [_clock setRate:0 time:kCMTimeZero];
    [_display flushAndRemoveImage];
    [_sound flush];
    if (_videoDecoder) avcodec_free_context(&_videoDecoder);
    if (_audioDecoder) avcodec_free_context(&_audioDecoder);
    if (_subtitleDecoder) avcodec_free_context(&_subtitleDecoder);
    if (_format) avformat_close_input(&_format);
    if (_hardware) av_buffer_unref(&_hardware);
    if (_scaler) { sws_freeContext(_scaler); _scaler = NULL; }
    if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
    if (_resampler) swr_free(&_resampler);
    if (_soundFormat) { CFRelease(_soundFormat); _soundFormat = NULL; }
    if (_packet) av_packet_free(&_packet);
    if (_frame) av_frame_free(&_frame);
    _videoStream = _audioStream = _subtitleStream = -1;
    _atEnd = _anchored = _saidEnded = NO;
}

- (nullable AVCodecContext *)decoderForStream:(int)index {
    AVStream *stream = _format->streams[index];
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) return NULL;
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context) return NULL;
    avcodec_parameters_to_context(context, stream->codecpar);
    context->pkt_timebase = stream->time_base;
    if (codec->type == AVMEDIA_TYPE_VIDEO) {
        BOOL systemDecodes = NO;
        for (int number = 0;; number++) {
            const AVCodecHWConfig *config = avcodec_get_hw_config(codec, number);
            if (!config) break;
            if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX) systemDecodes = YES;
        }
        if (systemDecodes && !_hardware) av_hwdevice_ctx_create(&_hardware, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0);
        if (systemDecodes && _hardware) {
            context->hw_device_ctx = av_buffer_ref(_hardware);
            context->get_format = ChoosePixelFormat;
        }
        context->thread_count = 0;
    }
    if (avcodec_open2(context, codec, NULL) < 0) {
        avcodec_free_context(&context);
        return NULL;
    }
    return context;
}

- (void)openMovie:(NSURL *)url headers:(nullable NSDictionary<NSString *, NSString *> *)headers start:(double)start subtitleFiles:(nullable NSArray<NSDictionary<NSString *, id> *> *)files session:(NSInteger)session {
    NSString *why = nil;
    _format = OpenMovie(url, headers, &why);
    if (!_format) {
        [self failWith:why ?: @"First Row couldn't open it." session:session];
        return;
    }
    _startOffset = _format->start_time != AV_NOPTS_VALUE ? _format->start_time / (double)AV_TIME_BASE : 0;
    _videoStream = av_find_best_stream(_format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (_videoStream >= 0 && (_format->streams[_videoStream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) _videoStream = -1;
    _audioStream = av_find_best_stream(_format, AVMEDIA_TYPE_AUDIO, -1, _videoStream, NULL, 0);
    if (_videoStream >= 0) _videoDecoder = [self decoderForStream:_videoStream];
    if (_audioStream >= 0) _audioDecoder = [self decoderForStream:_audioStream];
    if (!_videoDecoder && !_audioDecoder) {
        [self failWith:@"First Row has no decoder for this kind of movie." session:session];
        return;
    }
    if (!_videoDecoder) _videoStream = -1;
    if (!_audioDecoder) _audioStream = -1;
    _packet = av_packet_alloc();
    _frame = av_frame_alloc();

    // What the movie has, for the menus: its length, its tracks, its chapters.
    NSMutableArray *chapters = [NSMutableArray array];
    for (unsigned number = 0; number < _format->nb_chapters; number++) {
        AVChapter *chapter = _format->chapters[number];
        double at = chapter->start * av_q2d(chapter->time_base) - _startOffset;
        [chapters addObject:@{KeyStart: @(MAX(0, at)), KeyTitle: Tag(chapter->metadata, "title") ?: @""}];
    }
    NSMutableDictionary<NSNumber *, NSArray<FROlderCue *> *> *fileCues = [NSMutableDictionary dictionary];
    NSMutableArray *fileTracks = [NSMutableArray array];
    NSInteger number = 1000;
    for (NSDictionary<NSString *, id> *file in files ?: @[]) {
        NSURL *address = file[KeyURL];
        if (![address isKindOfClass:NSURL.class] || !address.isFileURL) continue;
        NSArray<FROlderCue *> *cues = [self cuesInFile:address];
        if (!cues.count) continue;
        fileCues[@(number)] = cues;
        [fileTracks addObject:@{KeyID: @(number), KeyName: file[KeyName] ?: address.lastPathComponent, KeyLanguage: file[KeyLanguage] ?: @"", KeyCodec: address.pathExtension.lowercaseString}];
        number += 1;
    }
    double duration = _format->duration != AV_NOPTS_VALUE ? _format->duration / (double)AV_TIME_BASE : 0;
    @synchronized (self) {
        if (session != _session) return;
        _duration = MAX(0, duration);
        _chapters = chapters;
        _fileCues = fileCues;
    }
    [self tellOfTracksWithFiles:fileTracks];
    _dropBefore = -1;
    _videoAhead = _audioAhead = 0;
    if (start > 0.5) {
        [self jumpTo:start exactly:YES];
    } else {
        [_clock setRate:0 time:kCMTimeZero];
    }
    [self changed];
    [self pump:session];
}

/// The movie's own tracks, with the subtitle files beside it after its own subtitles.
- (void)tellOfTracksWithFiles:(nullable NSArray<NSDictionary<NSString *, id> *> *)fileTracks {
    NSMutableArray *audio = [NSMutableArray array];
    NSMutableArray *subtitles = [NSMutableArray array];
    NSInteger chosenSubtitle;
    NSArray *known;
    @synchronized (self) {
        chosenSubtitle = _chosenSubtitle;
        known = _subtitleTracks;
    }
    for (unsigned index = 0; index < _format->nb_streams; index++) {
        AVStream *stream = _format->streams[index];
        AVCodecParameters *kind = stream->codecpar;
        const char *codec = avcodec_get_name(kind->codec_id);
        NSMutableDictionary *track = [@{
            KeyID: @(index),
            KeyName: Tag(stream->metadata, "title") ?: @"",
            KeyLanguage: Tag(stream->metadata, "language") ?: @"",
            KeyCodec: codec ? @(codec) : @"",
        } mutableCopy];
        if (kind->codec_type == AVMEDIA_TYPE_AUDIO) {
            track[KeyChannels] = @(kind->ch_layout.nb_channels);
            track[KeyIsChosen] = @((int)index == _audioStream);
            [audio addObject:track];
        } else if (kind->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            track[KeyIsChosen] = @((NSInteger)index == chosenSubtitle);
            track[KeyIsForced] = @((stream->disposition & AV_DISPOSITION_FORCED) != 0);
            [subtitles addObject:track];
        }
    }
    // (The files' tracks are kept from when the movie was opened.)
    NSArray *files = fileTracks;
    if (!files) {
        NSMutableArray *kept = [NSMutableArray array];
        for (NSDictionary *track in known) {
            if ([track[KeyID] integerValue] >= 1000) [kept addObject:track];
        }
        files = kept;
    }
    for (NSDictionary *track in files) {
        NSMutableDictionary *copy = [track mutableCopy];
        copy[KeyIsChosen] = @([track[KeyID] integerValue] == chosenSubtitle);
        copy[KeyIsForced] = @NO;
        [subtitles addObject:copy];
    }
    @synchronized (self) {
        _audioTracks = audio;
        _subtitleTracks = subtitles;
    }
}

// MARK: Reading and decoding

/// Reads on while there is less than a little over half a second decoded ahead of what is
/// showing, then looks again in a moment. It runs for as long as the movie is open.
- (void)pump:(NSInteger)session {
    if (![self isCurrent:session] || !_format) return;
    if (_display.status == AVQueuedSampleBufferRenderingStatusFailed) {
        // (The layer has given up, as it does when an iPhone app comes back from the
        // background: it is emptied, and filled again from where the movie is.)
        [_display flush];
        [self jumpTo:[self clockSeconds] exactly:YES];
    }
    for (int packets = 0; packets < 80 && !_atEnd; packets++) {
        double now = [self clockSeconds];
        BOOL wantsPicture = _videoDecoder && _videoAhead - now < 0.6 && _display.isReadyForMoreMediaData;
        BOOL wantsSound = _audioDecoder && _audioAhead - now < 0.6 && _sound.isReadyForMoreMediaData;
        if (!wantsPicture && !wantsSound) break;
        int result = av_read_frame(_format, _packet);
        if (result < 0) {
            if (_videoDecoder) [self decodePicture:NULL];
            if (_audioDecoder) [self decodeSound:NULL];
            _atEnd = YES;
            if (!_anchored) [self anchorAt:MAX(_videoAhead, _audioAhead)];
            break;
        }
        if (_packet->stream_index == _videoStream) [self decodePicture:_packet];
        else if (_packet->stream_index == _audioStream) [self decodeSound:_packet];
        else if (_packet->stream_index == _subtitleStream && _subtitleDecoder) [self decodeSubtitle:_packet into:nil];
        av_packet_unref(_packet);
    }
    if (_atEnd && _anchored && !_saidEnded && [self clockSeconds] >= MAX(_videoAhead, _audioAhead) - 0.05) {
        _saidEnded = YES;
        _clock.rate = 0;
        @synchronized (self) {
            if (session == _session) _phase = @"ended";
        }
        [self changed];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((_atEnd ? 0.05 : 0.012) * NSEC_PER_SEC)), _work, ^{
        [self pump:session];
    });
}

- (double)clockSeconds {
    double seconds = CMTimeGetSeconds(CMTimebaseGetTime(_clock.timebase));
    return isfinite(seconds) ? seconds : 0;
}

/// The first picture (or sound, with no picture) after opening or moving: the clock is set to
/// its time, and started if the movie is to play.
- (void)anchorAt:(double)time {
    if (_anchored) return;
    _anchored = YES;
    BOOL plays;
    double speed;
    @synchronized (self) {
        plays = _wantsPlay;
        speed = _speed;
        _isAnchored = YES;
        _hasPicture = YES;
        if (![_phase isEqualToString:@"failed"] && ![_phase isEqualToString:@"idle"]) _phase = plays ? @"playing" : @"paused";
    }
    [_clock setRate:(plays ? (float)speed : 0) time:CMTimeMakeWithSeconds(time, 90000)];
    [self changed];
}

- (void)decodePicture:(nullable AVPacket *)packet {
    if (avcodec_send_packet(_videoDecoder, packet) < 0 && packet) return;
    AVStream *stream = _format->streams[_videoStream];
    while (avcodec_receive_frame(_videoDecoder, _frame) == 0) {
        int64_t stamp = _frame->best_effort_timestamp;
        double time = stamp != AV_NOPTS_VALUE ? stamp * av_q2d(stream->time_base) - _startOffset : _videoAhead + 0.04;
        if (time + 0.001 >= _dropBefore) [self show:_frame at:time];
        _videoAhead = time;
        av_frame_unref(_frame);
    }
}

- (void)show:(AVFrame *)frame at:(double)time {
    CVPixelBufferRef pixels = NULL;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        pixels = CVPixelBufferRetain((CVPixelBufferRef)frame->data[3]);
    } else {
        pixels = [self copyOf:frame];
    }
    if (!pixels) return;
    CMVideoFormatDescriptionRef description = NULL;
    CMSampleBufferRef sample = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &description) == noErr) {
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMakeWithSeconds(time, 90000), kCMTimeInvalid};
        if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixels, description, &timing, &sample) == noErr) {
            [_display enqueueSampleBuffer:sample];
            CFRelease(sample);
        }
        CFRelease(description);
    }
    CVPixelBufferRelease(pixels);
    // The picture's shape, as it is to be shown (its pixels aren't always square).
    double wide = frame->width;
    if (frame->sample_aspect_ratio.num > 0 && frame->sample_aspect_ratio.den > 0) wide *= av_q2d(frame->sample_aspect_ratio);
    CGSize shape = CGSizeMake(round(wide), frame->height);
    BOOL isNew = NO;
    @synchronized (self) {
        if (!CGSizeEqualToSize(shape, _pictureSize)) {
            _pictureSize = shape;
            isNew = YES;
        }
    }
    if (isNew) [self changed];
    [self anchorAt:time];
}

/// A frame FFmpeg decoded itself, copied into a buffer the system's layer takes.
- (nullable CVPixelBufferRef)copyOf:(AVFrame *)frame CF_RETURNS_RETAINED {
    OSType kind = frame->color_range == AVCOL_RANGE_JPEG ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    if (!_pool || _poolWidth != frame->width || _poolHeight != frame->height || _poolKind != kind) {
        if (_pool) CVPixelBufferPoolRelease(_pool);
        _pool = NULL;
        NSDictionary *wanted = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kind),
            (id)kCVPixelBufferWidthKey: @(frame->width),
            (id)kCVPixelBufferHeightKey: @(frame->height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)wanted, &_pool);
        _poolWidth = frame->width;
        _poolHeight = frame->height;
        _poolKind = kind;
    }
    CVPixelBufferRef pixels = NULL;
    if (!_pool || CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _pool, &pixels) != kCVReturnSuccess) return NULL;
    _scaler = sws_getCachedContext(_scaler, frame->width, frame->height, (enum AVPixelFormat)frame->format, frame->width, frame->height, AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
    if (!_scaler) {
        CVPixelBufferRelease(pixels);
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pixels, 0);
    uint8_t *planes[4] = {CVPixelBufferGetBaseAddressOfPlane(pixels, 0), CVPixelBufferGetBaseAddressOfPlane(pixels, 1), NULL, NULL};
    int strides[4] = {(int)CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(pixels, 1), 0, 0};
    sws_scale(_scaler, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, planes, strides);
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    BOOL isHD = frame->colorspace == AVCOL_SPC_BT709 || (frame->colorspace == AVCOL_SPC_UNSPECIFIED && frame->height >= 720);
    CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, isHD ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return pixels;
}

- (void)decodeSound:(nullable AVPacket *)packet {
    if (avcodec_send_packet(_audioDecoder, packet) < 0 && packet) return;
    AVStream *stream = _format->streams[_audioStream];
    while (avcodec_receive_frame(_audioDecoder, _frame) == 0) {
        int rate = _frame->sample_rate;
        int channels = _frame->ch_layout.nb_channels;
        if (rate > 0 && channels > 0 && _frame->nb_samples > 0) {
            double time = _frame->pts != AV_NOPTS_VALUE ? _frame->pts * av_q2d(stream->time_base) - _startOffset : _audioAhead;
            if (!_resampler || _resamplerRate != rate || _resamplerFormat != _frame->format || _resamplerChannels != channels) {
                if (_resampler) swr_free(&_resampler);
                AVChannelLayout from;
                if (_frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) av_channel_layout_default(&from, channels);
                else av_channel_layout_copy(&from, &_frame->ch_layout);
                AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
                swr_alloc_set_opts2(&_resampler, &stereo, AV_SAMPLE_FMT_FLT, rate, &from, (enum AVSampleFormat)_frame->format, rate, 0, NULL);
                av_channel_layout_uninit(&from);
                if (!_resampler || swr_init(_resampler) < 0) {
                    if (_resampler) swr_free(&_resampler);
                    av_frame_unref(_frame);
                    continue;
                }
                _resamplerRate = rate;
                _resamplerFormat = _frame->format;
                _resamplerChannels = channels;
            }
            int room = swr_get_out_samples(_resampler, _frame->nb_samples);
            float *samples = malloc((size_t)room * 2 * sizeof(float));
            uint8_t *out[1] = {(uint8_t *)samples};
            int made = samples ? swr_convert(_resampler, out, room, (const uint8_t **)_frame->extended_data, _frame->nb_samples) : 0;
            double length = made > 0 ? made / (double)rate : 0;
            if (made > 0 && time + length >= _dropBefore) {
                [self playSamples:samples count:made rate:rate at:time];
                samples = NULL;
            }
            free(samples);
            _audioAhead = time + length;
            if (!_videoDecoder && made > 0) [self anchorAt:time];
        }
        av_frame_unref(_frame);
    }
}

/// Hands sound to the system: two channels of floats. (The block of samples is the buffer's
/// to free from here on.)
- (void)playSamples:(float *)samples count:(int)count rate:(int)rate at:(double)time {
    if (!_soundFormat || _soundRate != rate) {
        if (_soundFormat) CFRelease(_soundFormat);
        _soundFormat = NULL;
        AudioStreamBasicDescription shape = {0};
        shape.mSampleRate = rate;
        shape.mFormatID = kAudioFormatLinearPCM;
        shape.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        shape.mChannelsPerFrame = 2;
        shape.mBitsPerChannel = 32;
        shape.mBytesPerFrame = 8;
        shape.mBytesPerPacket = 8;
        shape.mFramesPerPacket = 1;
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &shape, 0, NULL, 0, NULL, NULL, &_soundFormat);
        _soundRate = rate;
    }
    size_t bytes = (size_t)count * 8;
    CMBlockBufferRef block = NULL;
    if (!_soundFormat || CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, samples, bytes, kCFAllocatorMalloc, NULL, 0, bytes, 0, &block) != noErr) {
        free(samples);
        return;
    }
    CMSampleBufferRef sample = NULL;
    if (CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, block, _soundFormat, count, CMTimeMakeWithSeconds(time, rate), NULL, &sample) == noErr) {
        [_sound enqueueSampleBuffer:sample];
        CFRelease(sample);
    }
    CFRelease(block);
}

// MARK: Subtitles

/// Decodes a subtitle packet into cues. With `list`, they are added to it (a file's, read all
/// at once); without, to the movie's own, which are shown as the movie reaches them.
- (void)decodeSubtitle:(AVPacket *)packet into:(nullable NSMutableArray<FROlderCue *> *)list {
    [self decodeSubtitle:packet with:_subtitleDecoder timeBase:_format->streams[packet->stream_index]->time_base offset:_startOffset into:list];
}

- (void)decodeSubtitle:(AVPacket *)packet with:(AVCodecContext *)decoder timeBase:(AVRational)timeBase offset:(double)offset into:(nullable NSMutableArray<FROlderCue *> *)list {
    AVSubtitle subtitle;
    int got = 0;
    if (avcodec_decode_subtitle2(decoder, &subtitle, &got, packet) < 0 || !got) return;
    double base = packet->pts != AV_NOPTS_VALUE ? packet->pts * av_q2d(timeBase) - offset : 0;
    double start = base + subtitle.start_display_time / 1000.0;
    double end = INFINITY;
    if (subtitle.end_display_time > 0 && subtitle.end_display_time != UINT32_MAX) end = base + subtitle.end_display_time / 1000.0;
    else if (packet->duration > 0) end = base + packet->duration * av_q2d(timeBase);
    CGSize canvas = CGSizeMake(decoder->width, decoder->height);
    if (canvas.width <= 0 || canvas.height <= 0) {
        @synchronized (self) { canvas = _pictureSize; }
    }
    NSMutableArray<FROlderCue *> *made = [NSMutableArray array];
    for (unsigned number = 0; number < subtitle.num_rects; number++) {
        AVSubtitleRect *rect = subtitle.rects[number];
        FROlderCue *cue = [FROlderCue new];
        cue.start = start;
        cue.end = end;
        if (rect->type == SUBTITLE_BITMAP) {
            CGImageRef image = CreateSubtitleImage(rect);
            if (!image || canvas.width <= 0 || canvas.height <= 0) {
                if (image) CGImageRelease(image);
                continue;
            }
            cue.image = image;
            CGImageRelease(image);
            cue.place = CGRectMake(rect->x / canvas.width, rect->y / canvas.height, rect->w / canvas.width, rect->h / canvas.height);
            cue.canvas = canvas;
        } else {
            NSString *words = rect->ass ? PlainWords(rect->ass) : (rect->text ? [NSString stringWithUTF8String:rect->text] : nil);
            if (!words.length) continue;
            cue.text = words;
        }
        [made addObject:cue];
    }
    avsubtitle_free(&subtitle);
    @synchronized (self) {
        NSMutableArray<FROlderCue *> *cues = list ?: _cues;
        // A subtitle with no end stays until the next one comes (which may be an empty one,
        // sent only to clear it).
        for (FROlderCue *earlier in cues) {
            if (isinf(earlier.end) && earlier.start < start) earlier.end = start;
        }
        for (FROlderCue *cue in made) {
            cue.number = ++_cueNumber;
            [cues addObject:cue];
        }
        if (!list && cues.count > 400) [cues removeObjectsInRange:NSMakeRange(0, cues.count - 400)];
    }
}

/// Every subtitle in a file kept beside the movie.
- (NSArray<FROlderCue *> *)cuesInFile:(NSURL *)file {
    AVFormatContext *format = OpenMovie(file, nil, NULL);
    if (!format) return @[];
    NSMutableArray<FROlderCue *> *cues = [NSMutableArray array];
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_SUBTITLE, -1, -1, NULL, 0);
    AVCodecContext *decoder = NULL;
    if (stream >= 0) {
        const AVCodec *codec = avcodec_find_decoder(format->streams[stream]->codecpar->codec_id);
        decoder = codec ? avcodec_alloc_context3(codec) : NULL;
        if (decoder) {
            avcodec_parameters_to_context(decoder, format->streams[stream]->codecpar);
            decoder->pkt_timebase = format->streams[stream]->time_base;
            if (avcodec_open2(decoder, codec, NULL) < 0) avcodec_free_context(&decoder);
        }
    }
    if (decoder) {
        AVPacket *packet = av_packet_alloc();
        for (int read = 0; read < 50000 && av_read_frame(format, packet) >= 0; read++) {
            if (packet->stream_index == stream) {
                [self decodeSubtitle:packet with:decoder timeBase:format->streams[stream]->time_base offset:0 into:cues];
            }
            av_packet_unref(packet);
        }
        av_packet_free(&packet);
        avcodec_free_context(&decoder);
    }
    avformat_close_input(&format);
    return cues;
}

- (NSArray<NSDictionary<NSString *, id> *> *)captions {
    @synchronized (self) { return _shownCaptions; }
}

/// (Asked for as often as First Row draws, which is what keeps the subtitles to their times.)
- (NSInteger)captionsRevision {
    double now = self.position;
    @synchronized (self) {
        NSArray<FROlderCue *> *cues = _chosenSubtitle >= 1000 ? (_fileCues[@(_chosenSubtitle)] ?: @[]) : (_chosenSubtitle >= 0 ? _cues : @[]);
        NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
        NSMutableArray<FROlderCue *> *showing = [NSMutableArray array];
        for (FROlderCue *cue in cues) {
            if (cue.start <= now && now < cue.end) {
                [numbers addObject:@(cue.number)];
                [showing addObject:cue];
            }
        }
        if (![numbers isEqualToArray:_shownCues]) {
            NSMutableArray *captions = [NSMutableArray array];
            for (FROlderCue *cue in showing) {
                if (cue.image) {
                    [captions addObject:@{
                        KeyImage: (__bridge id)cue.image,
                        KeyX: @(cue.place.origin.x), KeyY: @(cue.place.origin.y),
                        KeyWidth: @(cue.place.size.width), KeyHeight: @(cue.place.size.height),
                        KeyCanvasWidth: @(cue.canvas.width), KeyCanvasHeight: @(cue.canvas.height),
                    }];
                } else if (cue.text) {
                    [captions addObject:@{KeyText: cue.text}];
                }
            }
            _shownCues = numbers;
            _shownCaptions = captions;
            _revision += 1;
        }
        return _revision;
    }
}

// MARK: Tracks and chapters

- (NSArray<NSDictionary<NSString *, id> *> *)audioTracks {
    @synchronized (self) { return _audioTracks; }
}

- (NSArray<NSDictionary<NSString *, id> *> *)subtitleTracks {
    @synchronized (self) { return _subtitleTracks; }
}

- (NSArray<NSDictionary<NSString *, id> *> *)chapters {
    @synchronized (self) { return _chapters; }
}

- (void)chooseAudioTrack:(NSInteger)identifier {
    NSInteger session;
    @synchronized (self) { session = _session; }
    dispatch_async(_work, ^{
        if (![self isCurrent:session] || !self->_format) return;
        if (identifier < 0 || identifier >= (NSInteger)self->_format->nb_streams || identifier == self->_audioStream) return;
        if (self->_format->streams[identifier]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) return;
        int before = self->_audioStream;
        AVCodecContext *old = self->_audioDecoder;
        self->_audioStream = (int)identifier;
        self->_audioDecoder = [self decoderForStream:(int)identifier];
        if (!self->_audioDecoder) {
            // (No decoder for that one: the track that was playing stays.)
            self->_audioStream = before;
            self->_audioDecoder = old;
            return;
        }
        if (old) avcodec_free_context(&old);
        [self tellOfTracksWithFiles:nil];
        // (From where the movie is, so that the new track starts in step.)
        [self jumpTo:[self clockSeconds] exactly:YES];
        [self changed];
    });
}

- (void)chooseSubtitleTrack:(NSInteger)identifier {
    NSInteger session;
    @synchronized (self) {
        session = _session;
        _chosenSubtitle = identifier;
        [_cues removeAllObjects];
        _shownCues = @[];
        _shownCaptions = @[];
        _revision += 1;
    }
    dispatch_async(_work, ^{
        if (![self isCurrent:session] || !self->_format) return;
        if (self->_subtitleDecoder) avcodec_free_context(&self->_subtitleDecoder);
        self->_subtitleStream = -1;
        if (identifier >= 0 && identifier < (NSInteger)self->_format->nb_streams && self->_format->streams[identifier]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
            self->_subtitleDecoder = [self decoderForStream:(int)identifier];
            if (self->_subtitleDecoder) {
                self->_subtitleStream = (int)identifier;
                // (Read again from a little before where the movie is, for what is showing now.)
                [self jumpTo:[self clockSeconds] exactly:YES];
            }
        }
        [self tellOfTracksWithFiles:nil];
        [self changed];
    });
}

// MARK: Moving about

/// Goes to a time in the movie. Exactly: the pictures and sound before it are decoded but
/// not shown, so that it starts on the time asked for and not on the key frame before it.
- (BOOL)jumpTo:(double)seconds exactly:(BOOL)exactly {
    double length;
    @synchronized (self) { length = _duration; }
    double target = MAX(0, seconds);
    if (length > 0.5) target = MIN(target, length - 0.25);
    int64_t stamp = (int64_t)((target + _startOffset) * AV_TIME_BASE);
    int result = avformat_seek_file(_format, -1, INT64_MIN, stamp, stamp, 0);
    if (result < 0) result = av_seek_frame(_format, -1, stamp, AVSEEK_FLAG_BACKWARD);
    if (result < 0) return NO;
    if (_videoDecoder) avcodec_flush_buffers(_videoDecoder);
    if (_audioDecoder) avcodec_flush_buffers(_audioDecoder);
    if (_subtitleDecoder) avcodec_flush_buffers(_subtitleDecoder);
    [_clock setRate:0 time:CMTimeMakeWithSeconds(target, 90000)];
    [_display flush];
    [_sound flush];
    _dropBefore = exactly ? target : -1;
    _videoAhead = _audioAhead = target;
    _atEnd = NO;
    _anchored = NO;
    _saidEnded = NO;
    @synchronized (self) {
        _isAnchored = NO;
        _restingPosition = target;
        [_cues removeAllObjects];
        if ([_phase isEqualToString:@"ended"]) _phase = _wantsPlay ? @"playing" : @"paused";
    }
    return YES;
}

- (void)seekTo:(double)seconds exactly:(BOOL)exactly then:(void (^_Nullable)(BOOL))done {
    NSInteger session;
    @synchronized (self) { session = _session; }
    dispatch_async(_work, ^{
        BOOL moved = [self isCurrent:session] && self->_format && [self jumpTo:seconds exactly:exactly];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) done(moved);
            if (self.onChange) self.onChange();
        });
    });
}

- (void)play {
    NSInteger session;
    @synchronized (self) {
        session = _session;
        _wantsPlay = YES;
        if ([_phase isEqualToString:@"paused"]) _phase = @"playing";
    }
    dispatch_async(_work, ^{
        if (![self isCurrent:session] || !self->_anchored || self->_saidEnded) return;
        double speed;
        @synchronized (self) { speed = self->_speed; }
        self->_clock.rate = (float)speed;
    });
    [self changed];
}

- (void)pause {
    NSInteger session;
    @synchronized (self) {
        session = _session;
        _wantsPlay = NO;
        if ([_phase isEqualToString:@"playing"]) _phase = @"paused";
    }
    dispatch_async(_work, ^{
        if (![self isCurrent:session]) return;
        self->_clock.rate = 0;
    });
    [self changed];
}

- (double)speed {
    @synchronized (self) { return _speed; }
}

- (void)setSpeed:(double)speed {
    NSInteger session;
    BOOL plays;
    @synchronized (self) {
        _speed = MAX(0.1, speed);
        session = _session;
        plays = _wantsPlay;
    }
    dispatch_async(_work, ^{
        if (![self isCurrent:session] || !self->_anchored || !plays || self->_saidEnded) return;
        self->_clock.rate = (float)MAX(0.1, speed);
    });
}

- (BOOL)isMuted {
    @synchronized (self) { return _muted; }
}

- (void)setIsMuted:(BOOL)isMuted {
    @synchronized (self) { _muted = isMuted; }
    _sound.muted = isMuted;
}

// MARK: What it is doing

- (NSString *)phase {
    @synchronized (self) { return _phase; }
}

- (BOOL)isWaiting {
    @synchronized (self) { return _wantsPlay && ([_phase isEqualToString:@"opening"] || (!_isAnchored && [_phase isEqualToString:@"playing"])); }
}

- (nullable NSString *)failure {
    @synchronized (self) { return _failure; }
}

- (BOOL)hasPicture {
    @synchronized (self) { return _hasPicture; }
}

- (double)position {
    @synchronized (self) {
        // (While it is opening or moving, the clock hasn't been set to the new place yet.)
        if (!_isAnchored) return _restingPosition;
    }
    double seconds = CMTimeGetSeconds(CMTimebaseGetTime(_clock.timebase));
    return isfinite(seconds) ? MAX(0, seconds) : 0;
}

- (double)duration {
    @synchronized (self) { return _duration; }
}

- (NSString *)pictureKind { return @"sdr"; }

- (CGSize)pictureSize {
    @synchronized (self) { return _pictureSize; }
}

- (nullable AVPlayer *)systemPlayer { return nil; }

// (Picture in picture is the main engine's.)
- (BOOL)keepsPictureInPictureReady { return NO; }
- (void)setKeepsPictureInPictureReady:(BOOL)keeps {}
- (BOOL)isInPictureInPicture { return NO; }
- (void)leavePictureInPicture {}

@end

// MARK: - The engine

@interface FirstRowMediaEngineOlder : NSObject <FirstRowMediaEngineProviding>
@end

@implementation FirstRowMediaEngineOlder {
    FROlderPlayer *_player;
    dispatch_queue_t _looking;
}

- (instancetype)init {
    if ((self = [super init])) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            av_log_set_level(AV_LOG_ERROR);
            avformat_network_init();
        });
        _looking = dispatch_queue_create("firstrow.mediaengine.older.looking", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (NSInteger)interfaceVersion { return InterfaceVersion; }

- (NSString *)engineDescription {
    return [NSString stringWithFormat:@"FFmpeg %s (for older systems)", av_version_info()];
}

- (nullable NSObject *)player {
    if (!_player) _player = [FROlderPlayer new];
    return _player;
}

- (void)describe:(NSURL *)url then:(void (^)(NSDictionary<NSString *, id> *))answer {
    dispatch_async(_looking, ^{
        NSMutableDictionary<NSString *, id> *found = [NSMutableDictionary dictionary];
        NSString *why = nil;
        AVFormatContext *format = OpenMovie(url, nil, &why);
        if (!format) {
            found[KeyError] = why ?: @"First Row couldn't open it.";
        } else {
            if (format->duration != AV_NOPTS_VALUE) found[KeyDuration] = @(MAX(0, format->duration / (double)AV_TIME_BASE));
            NSString *title = Tag(format->metadata, "title");
            if (title) found[KeyTitle] = title;
            BOOL hasVideo = NO;
            for (unsigned index = 0; index < format->nb_streams; index++) {
                AVStream *stream = format->streams[index];
                if (stream->codecpar->codec_type != AVMEDIA_TYPE_VIDEO) continue;
                if (stream->disposition & AV_DISPOSITION_ATTACHED_PIC) {
                    if (stream->attached_pic.data && stream->attached_pic.size > 0) {
                        found[KeyArtwork] = [NSData dataWithBytes:stream->attached_pic.data length:(NSUInteger)stream->attached_pic.size];
                    }
                } else if (!hasVideo) {
                    hasVideo = YES;
                    found[KeyWidth] = @(stream->codecpar->width);
                    found[KeyHeight] = @(stream->codecpar->height);
                }
            }
            found[KeyHasVideo] = @(hasVideo);
            avformat_close_input(&format);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ answer(found); });
    });
}

- (void)pictureOf:(NSURL *)url details:(NSDictionary<NSString *, id> *)details then:(void (^)(CGImageRef _Nullable))answer {
    double seconds = [details[KeySeconds] doubleValue];
    double longestSide = [details[KeyLongestSide] doubleValue];
    dispatch_async(_looking, ^{
        CGImageRef image = [self newFrameOf:url at:seconds longestSide:longestSide > 0 ? longestSide : 1100];
        dispatch_async(dispatch_get_main_queue(), ^{
            answer(image);
            if (image) CGImageRelease(image);
        });
    });
}

/// A frame of a movie as an image: the first one at or after a time, decoded by FFmpeg itself.
- (nullable CGImageRef)newFrameOf:(NSURL *)url at:(double)seconds longestSide:(double)longestSide CF_RETURNS_RETAINED {
    AVFormatContext *format = OpenMovie(url, nil, NULL);
    if (!format) return NULL;
    CGImageRef image = NULL;
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    const AVCodec *codec = stream >= 0 ? avcodec_find_decoder(format->streams[stream]->codecpar->codec_id) : NULL;
    AVCodecContext *decoder = codec ? avcodec_alloc_context3(codec) : NULL;
    if (decoder) {
        avcodec_parameters_to_context(decoder, format->streams[stream]->codecpar);
        decoder->thread_count = 2;
        if (avcodec_open2(decoder, codec, NULL) < 0) avcodec_free_context(&decoder);
    }
    if (decoder) {
        double offset = format->start_time != AV_NOPTS_VALUE ? format->start_time / (double)AV_TIME_BASE : 0;
        double length = format->duration != AV_NOPTS_VALUE ? format->duration / (double)AV_TIME_BASE : 0;
        double target = length > 1 ? MIN(MAX(0, seconds), length * 0.9) : 0;
        if (target > 0.5) {
            int64_t stamp = (int64_t)((target + offset) * AV_TIME_BASE);
            if (avformat_seek_file(format, -1, INT64_MIN, stamp, stamp, 0) < 0) target = 0;
        }
        AVPacket *packet = av_packet_alloc();
        AVFrame *frame = av_frame_alloc();
        AVRational timeBase = format->streams[stream]->time_base;
        BOOL found = NO;
        for (int read = 0; read < 1500 && !found && av_read_frame(format, packet) >= 0; read++) {
            if (packet->stream_index == stream && avcodec_send_packet(decoder, packet) >= 0) {
                while (!found && avcodec_receive_frame(decoder, frame) == 0) {
                    double time = frame->best_effort_timestamp != AV_NOPTS_VALUE ? frame->best_effort_timestamp * av_q2d(timeBase) - offset : target;
                    // (Not one from well before the time, which is what a key frame can be.)
                    if (time + 0.5 >= target) found = YES;
                    else av_frame_unref(frame);
                }
            }
            av_packet_unref(packet);
        }
        if (found && frame->width > 0 && frame->height > 0) {
            double wide = frame->width;
            if (frame->sample_aspect_ratio.num > 0 && frame->sample_aspect_ratio.den > 0) wide *= av_q2d(frame->sample_aspect_ratio);
            double shrink = MIN(1, longestSide / MAX(wide, (double)frame->height));
            int width = MAX(2, (int)round(wide * shrink)), height = MAX(2, (int)round(frame->height * shrink));
            struct SwsContext *scaler = sws_getContext(frame->width, frame->height, (enum AVPixelFormat)frame->format, width, height, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
            NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)width * (NSUInteger)height * 4];
            if (scaler && pixels) {
                uint8_t *planes[4] = {pixels.mutableBytes, NULL, NULL, NULL};
                int strides[4] = {width * 4, 0, 0, 0};
                sws_scale(scaler, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, planes, strides);
                CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
                CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
                image = CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)width * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast, provider, NULL, false, kCGRenderingIntentDefault);
                CGColorSpaceRelease(space);
                CGDataProviderRelease(provider);
            }
            if (scaler) sws_freeContext(scaler);
        }
        av_frame_free(&frame);
        av_packet_free(&packet);
        avcodec_free_context(&decoder);
    }
    avformat_close_input(&format);
    return image;
}

- (void)ask:(NSString *)question details:(NSDictionary<NSString *, id> *)details then:(void (^)(NSDictionary<NSString *, id> *))answer {
    // (Shared folders are read by the main engine, on the systems it runs on.)
    dispatch_async(dispatch_get_main_queue(), ^{
        answer(@{KeyError: @"This needs a newer system."});
    });
}

@end

NS_ASSUME_NONNULL_END
