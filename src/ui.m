// language: Objective-C, file: src/ui.m, Vertex Native iOS UI
#import "ui.h"
#import "vstore.h"
#import "tsx.h"
#import "tsx_system.h"
#import <objc/runtime.h>

@interface VertexItemCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, strong) UILabel *priceBadge;
@end

@implementation VertexItemCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.11 alpha:1.0];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(14, 10, 52, 52)];
        _iconView.layer.cornerRadius = 11;
        _iconView.clipsToBounds = YES;
        _iconView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
        [self.contentView addSubview:_iconView];

        _priceBadge = [[UILabel alloc] initWithFrame:CGRectZero];
        _priceBadge.font = [UIFont boldSystemFontOfSize:12];
        _priceBadge.textColor = [UIColor whiteColor];
        _priceBadge.textAlignment = NSTextAlignmentCenter;
        _priceBadge.backgroundColor = [UIColor colorWithRed:0.48 green:0.23 blue:0.93 alpha:1.0]; // Neon purple
        _priceBadge.layer.cornerRadius = 12;
        _priceBadge.clipsToBounds = YES;
        [self.contentView addSubview:_priceBadge];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont boldSystemFontOfSize:15];
        _titleLabel.textColor = [UIColor whiteColor];
        [self.contentView addSubview:_titleLabel];

        _subLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subLabel.font = [UIFont systemFontOfSize:12];
        _subLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
        [self.contentView addSubview:_subLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;

    _iconView.frame = CGRectMake(14, (h - 52) / 2.0, 52, 52);

    CGFloat badgeW = 68;
    CGFloat badgeH = 26;
    _priceBadge.frame = CGRectMake(w - badgeW - 14, (h - badgeH) / 2.0, badgeW, badgeH);

    CGFloat textX = 76;
    CGFloat textW = w - textX - badgeW - 24;
    _titleLabel.frame = CGRectMake(textX, 14, textW, 20);
    _subLabel.frame = CGRectMake(textX, 36, textW, 18);
}
@end

@interface VertexRootViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, strong) NSCache *imageCache;
@end

@implementation VertexRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VERTEX";
    self.view.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.07 alpha:1.0];

    self.items = [NSMutableArray array];
    self.imageCache = [NSCache new];

    if (self.navigationController) {
        self.navigationController.navigationBar.barTintColor = [UIColor colorWithRed:0.07 green:0.07 blue:0.10 alpha:1.0];
        self.navigationController.navigationBar.tintColor = [UIColor colorWithRed:0.55 green:0.35 blue:1.0 alpha:1.0];
        self.navigationController.navigationBar.translucent = NO;
        self.navigationController.navigationBar.titleTextAttributes = @{
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSFontAttributeName: [UIFont boldSystemFontOfSize:18]
        };
    }

    _searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.placeholder = @"Buscar apps na App Store...";
    _searchBar.delegate = self;
    _searchBar.barStyle = UIBarStyleBlack;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    [self.view addSubview:_searchBar];

    NSArray *segments = @[@"Grátis", @"Pagos", @"Top", @"Instalados"];
    _segmentedControl = [[UISegmentedControl alloc] initWithItems:segments];
    _segmentedControl.translatesAutoresizingMaskIntoConstraints = NO;
    _segmentedControl.selectedSegmentIndex = 0;
    _segmentedControl.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    [_segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_segmentedControl];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.07 alpha:1.0];
    _tableView.separatorColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    _tableView.rowHeight = 72;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [_tableView registerClass:[VertexItemCell class] forCellReuseIdentifier:@"Cell"];
    [self.view addSubview:_tableView];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [self.view addSubview:_spinner];

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    refresh.tintColor = [UIColor colorWithRed:0.55 green:0.35 blue:1.0 alpha:1.0];
    [refresh addTarget:self action:@selector(loadCurrentSegment) forControlEvents:UIControlEventValueChanged];
    _tableView.refreshControl = refresh;

    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_segmentedControl.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:4],
        [_segmentedControl.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [_segmentedControl.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [_segmentedControl.heightAnchor constraintEqualToConstant:32],

        [_tableView.topAnchor constraintEqualToAnchor:_segmentedControl.bottomAnchor constant:8],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];

    [self loadCurrentSegment];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    [self.view endEditing:YES];
    [self loadCurrentSegment];
}

- (void)loadCurrentSegment {
    NSInteger idx = _segmentedControl.selectedSegmentIndex;
    if (idx == 3) {
        [self loadInstalledApps];
        return;
    }

    NSString *kind = (idx == 0) ? @"free" : (idx == 1 ? @"paid" : @"grossing");
    [self loadStoreChart:kind];
}

- (void)loadStoreChart:(NSString *)kind {
    [_spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        NSArray<VTSItem *> *res = [VTSAppStore chart:kind country:@"us" limit:50 error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            [self.tableView.refreshControl endRefreshing];
            if (res) {
                [self.items setArray:res];
                [self.tableView reloadData];
            } else {
                NSLog(@"chart err: %@", err);
            }
        });
    });
}

- (void)loadInstalledApps {
    [_spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *list = [NSMutableArray array];
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass) {
            LSApplicationWorkspace *ws = [wsClass performSelector:@selector(defaultWorkspace)];
            NSArray *apps = ws.allInstalledApplications;
            for (LSApplicationProxy *p in apps) {
                if (![p.bundleURL.path hasPrefix:@"/private/var/containers"]) continue;
                VTSItem *it = [VTSItem new];
                it.name = p.localizedName ?: p.bundleIdentifier;
                it.bundleId = p.bundleIdentifier;
                it.genre = @"App do Usuário";
                it.price = 0.0;
                [list addObject:it];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            [self.tableView.refreshControl endRefreshing];
            [self.items setArray:list];
            [self.tableView reloadData];
        });
    });
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSString *query = searchBar.text;
    if (query.length == 0) return;

    [_spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *err = nil;
        NSArray<VTSItem *> *res = [VTSAppStore search:query country:@"us" limit:50 error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (res) {
                [self.items setArray:res];
                [self.tableView reloadData];
            }
        });
    });
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    VertexItemCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    if (indexPath.row >= (NSInteger)self.items.count) return cell;

    VTSItem *it = self.items[indexPath.row];
    cell.titleLabel.text = it.name ?: @"Sem nome";
    cell.subLabel.text = [NSString stringWithFormat:@"%@ • %@", it.seller ?: @"Apple", it.genre ?: @"App"];
    cell.priceBadge.text = it.priceLabel ?: @"GET";

    if (_segmentedControl.selectedSegmentIndex == 3) {
        cell.priceBadge.text = @"ABRIR";
        cell.priceBadge.backgroundColor = [UIColor colorWithRed:0.18 green:0.65 blue:0.42 alpha:1.0];
    } else {
        cell.priceBadge.backgroundColor = it.paid ? [UIColor colorWithRed:0.85 green:0.35 blue:0.25 alpha:1.0]
                                                  : [UIColor colorWithRed:0.48 green:0.23 blue:0.93 alpha:1.0];
    }

    cell.iconView.image = nil;
    if (it.artwork.length > 0) {
        UIImage *cached = [self.imageCache objectForKey:it.artwork];
        if (cached) {
            cell.iconView.image = cached;
        } else {
            NSString *urlStr = it.artwork;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:urlStr]];
                if (data) {
                    UIImage *img = [UIImage imageWithData:data];
                    if (img) {
                        [self.imageCache setObject:img forKey:urlStr];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            VertexItemCell *c = (VertexItemCell *)[tableView cellForRowAtIndexPath:indexPath];
                            if (c) c.iconView.image = img;
                        });
                    }
                }
            });
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.items.count) return;
    VTSItem *it = self.items[indexPath.row];

    if (_segmentedControl.selectedSegmentIndex == 3) {
        // Installed app - launch it
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass && it.bundleId) {
            LSApplicationWorkspace *ws = [wsClass performSelector:@selector(defaultWorkspace)];
            [ws openApplicationWithBundleID:it.bundleId];
        }
        return;
    }

    NSString *msg = [NSString stringWithFormat:@"Bundle ID: %@\nCategoria: %@\nPreço: %@",
                     it.bundleId ?: @"N/A", it.genre ?: @"N/A", it.priceLabel ?: @"Grátis"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:it.name
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (it.storeUrl.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Abrir na App Store"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *action) {
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:it.storeUrl]
                                               options:@{}
                                     completionHandler:nil];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Fechar"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end

@implementation VertexAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    VertexRootViewController *vc = [VertexRootViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
