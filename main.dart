import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

// ─────────────────────────────────────────────────────────────
//  ENTRY POINT
// ─────────────────────────────────────────────────────────────

void main() {
  runApp(const StoryHubApp());
}

// ─────────────────────────────────────────────────────────────
//  DATA LAYER  →  Model + Repository
// ─────────────────────────────────────────────────────────────

/// A single story received from the REST API.
class Story {
  final int id;
  final int authorId;
  final String headline;
  final String content;

  const Story({
    required this.id,
    required this.authorId,
    required this.headline,
    required this.content,
  });

  factory Story.fromMap(Map<String, dynamic> map) {
    return Story(
      id: map['id'] as int,
      authorId: map['userId'] as int,
      headline: (map['title'] ?? '') as String,
      content: (map['body'] ?? '') as String,
    );
  }

  /// Rough reading time (200 words per minute).
  String get readingTime {
    final words = content.trim().split(RegExp(r'\s+')).length;
    final minutes = (words / 200).ceil();
    return '$minutes min read';
  }
}

/// Custom exception so the UI can show a friendly message.
class StoryException implements Exception {
  final String message;
  StoryException(this.message);

  @override
  String toString() => message;
}

/// Handles all network communication.
class StoryRepository {
  static const String _endpoint = 'https://jsonplaceholder.typicode.com/posts';

  final http.Client _client;

  StoryRepository({http.Client? client}) : _client = client ?? http.Client();

  Future<List<Story>> loadStories() async {
    final http.Response res;
    try {
      res = await _client
          .get(Uri.parse(_endpoint))
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw StoryException('Server is taking too long. Check your internet.');
    } catch (_) {
      throw StoryException('No internet connection.');
    }

    if (res.statusCode != 200) {
      throw StoryException('Server error (code ${res.statusCode}).');
    }

    final decoded = jsonDecode(res.body) as List<dynamic>;
    return decoded
        .map((e) => Story.fromMap(e as Map<String, dynamic>))
        .toList();
  }
}

// ─────────────────────────────────────────────────────────────
//  STATE MANAGEMENT  →  Provider (ChangeNotifier)
// ─────────────────────────────────────────────────────────────

enum FeedStatus { idle, loading, loaded, failed }

class FeedController extends ChangeNotifier {
  FeedController(this._repository);

  final StoryRepository _repository;

  FeedStatus _status = FeedStatus.idle;
  List<Story> _allStories = [];
  final Set<int> _bookmarkIds = {};
  String _query = '';
  String _errorText = '';

  // ---- getters ----
  FeedStatus get status => _status;
  String get errorText => _errorText;
  String get query => _query;
  int get bookmarkCount => _bookmarkIds.length;

  /// Stories filtered by the current search text (title only).
  List<Story> get visibleStories {
    if (_query.isEmpty) return List.unmodifiable(_allStories);
    final q = _query.toLowerCase();
    return _allStories
        .where((s) => s.headline.toLowerCase().contains(q))
        .toList();
  }

  List<Story> get bookmarkedStories =>
      _allStories.where((s) => _bookmarkIds.contains(s.id)).toList();

  bool isBookmarked(int id) => _bookmarkIds.contains(id);

  // ---- actions ----
  Future<void> load() async {
    _status = FeedStatus.loading;
    _errorText = '';
    notifyListeners();

    try {
      _allStories = await _repository.loadStories();
      _status = FeedStatus.loaded;
    } on StoryException catch (e) {
      _errorText = e.message;
      _status = FeedStatus.failed;
    } catch (_) {
      _errorText = 'Something went wrong. Please try again.';
      _status = FeedStatus.failed;
    }
    notifyListeners();
  }

  void updateQuery(String value) {
    _query = value.trim();
    notifyListeners();
  }

  /// Returns `true` if the story is now bookmarked.
  bool toggleBookmark(int id) {
    final added = _bookmarkIds.add(id);
    if (!added) _bookmarkIds.remove(id);
    notifyListeners();
    return added;
  }
}

// ─────────────────────────────────────────────────────────────
//  APP ROOT
// ─────────────────────────────────────────────────────────────

class StoryHubApp extends StatelessWidget {
  const StoryHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<FeedController>(
      create: (_) => FeedController(StoryRepository())..load(),
      child: MaterialApp(
        title: 'StoryHub',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.teal,
          brightness: Brightness.dark,
        ),
        home: const HomeShell(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  HOME SHELL  →  Bottom navigation (Feed / Saved)
// ─────────────────────────────────────────────────────────────

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    // Selector rebuilds only when the bookmark count changes.
    final savedCount = context.select<FeedController, int>(
      (c) => c.bookmarkCount,
    );

    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [FeedPage(), SavedPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.article_outlined),
            selectedIcon: Icon(Icons.article),
            label: 'Feed',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: savedCount > 0,
              label: Text('$savedCount'),
              child: const Icon(Icons.bookmark_border),
            ),
            selectedIcon: Badge(
              isLabelVisible: savedCount > 0,
              label: Text('$savedCount'),
              child: const Icon(Icons.bookmark),
            ),
            label: 'Saved',
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  FEED PAGE  →  Search + list + loading / error / empty states
// ─────────────────────────────────────────────────────────────

class FeedPage extends StatefulWidget {
  const FeedPage({super.key});

  @override
  State<FeedPage> createState() => _FeedPageState();
}

class _FeedPageState extends State<FeedPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Waits 300 ms after the user stops typing before filtering.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      context.read<FeedController>().updateQuery(value);
    });
    setState(() {}); // refresh clear button visibility
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchCtrl.clear();
    context.read<FeedController>().updateQuery('');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<FeedController>();

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- Header ----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text(
              'StoryHub',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Fresh stories from the API',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),

          // ---- Search ----
          Padding(
            padding: const EdgeInsets.all(16),
            child: SearchBar(
              controller: _searchCtrl,
              hintText: 'Find a story by title…',
              leading: const Icon(Icons.search),
              elevation: const WidgetStatePropertyAll(1),
              onChanged: _onSearchChanged,
              trailing: [
                if (_searchCtrl.text.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close),
                    onPressed: _clearSearch,
                  ),
              ],
            ),
          ),

          // ---- Body ----
          Expanded(child: _buildBody(controller)),
        ],
      ),
    );
  }

  Widget _buildBody(FeedController controller) {
    switch (controller.status) {
      case FeedStatus.idle:
      case FeedStatus.loading:
        return const Center(child: CircularProgressIndicator());

      case FeedStatus.failed:
        return StatusMessage(
          icon: Icons.wifi_off_rounded,
          title: 'Oops!',
          message: controller.errorText,
          action: FilledButton.tonalIcon(
            onPressed: controller.load,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        );

      case FeedStatus.loaded:
        final stories = controller.visibleStories;

        if (stories.isEmpty) {
          return StatusMessage(
            icon: Icons.search_off_rounded,
            title: 'No match',
            message: 'Nothing found for "${controller.query}".',
          );
        }

        return RefreshIndicator(
          onRefresh: controller.load,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            itemCount: stories.length + 1,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Text(
                  '${stories.length} stories',
                  style: Theme.of(context).textTheme.labelLarge,
                );
              }
              final story = stories[i - 1];
              return StoryTile(story: story, heroPrefix: 'feed');
            },
          ),
        );
    }
  }
}

// ─────────────────────────────────────────────────────────────
//  SAVED PAGE  →  Only bookmarked stories
// ─────────────────────────────────────────────────────────────

class SavedPage extends StatelessWidget {
  const SavedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final saved = context.watch<FeedController>().bookmarkedStories;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Text(
              'Saved Stories',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Expanded(
            child: saved.isEmpty
                ? const StatusMessage(
                    icon: Icons.bookmark_add_outlined,
                    title: 'Nothing saved yet',
                    message:
                        'Tap the bookmark icon on any story to keep it here.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: saved.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) =>
                        StoryTile(story: saved[i], heroPrefix: 'saved'),
                  ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  REUSABLE WIDGETS
// ─────────────────────────────────────────────────────────────

/// One story card in a list.
class StoryTile extends StatelessWidget {
  final Story story;
  final String heroPrefix;

  const StoryTile({super.key, required this.story, required this.heroPrefix});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saved = context.select<FeedController, bool>(
      (c) => c.isBookmarked(story.id),
    );
    final heroTag = '$heroPrefix-${story.id}';

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => StoryDetailPage(story: story, heroTag: heroTag),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Hero(
                tag: heroTag,
                child: StoryBadge(id: story.id),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      story.headline,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      story.content.replaceAll('\n', ' '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 14,
                          color: scheme.outline,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Author ${story.authorId}',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(width: 12),
                        Icon(Icons.schedule, size: 14, color: scheme.outline),
                        const SizedBox(width: 4),
                        Text(
                          story.readingTime,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              BookmarkButton(storyId: story.id, isSaved: saved),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded square showing the story number.
class StoryBadge extends StatelessWidget {
  final int id;
  final double size;

  const StoryBadge({super.key, required this.id, this.size = 46});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Text(
        '#$id',
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.bold,
          fontSize: size * 0.3,
        ),
      ),
    );
  }
}

/// Bookmark toggle with a small SnackBar feedback.
class BookmarkButton extends StatelessWidget {
  final int storyId;
  final bool isSaved;

  const BookmarkButton({
    super.key,
    required this.storyId,
    required this.isSaved,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: isSaved ? 'Remove bookmark' : 'Bookmark',
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: child),
        child: Icon(
          isSaved ? Icons.bookmark : Icons.bookmark_border,
          key: ValueKey(isSaved),
          color: isSaved ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
      onPressed: () {
        final added = context.read<FeedController>().toggleBookmark(storyId);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 1),
              content: Text(added ? 'Added to Saved' : 'Removed from Saved'),
            ),
          );
      },
    );
  }
}

/// Centered icon + text used for error / empty states.
class StatusMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const StatusMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: scheme.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
//  DETAIL PAGE
// ─────────────────────────────────────────────────────────────

class StoryDetailPage extends StatelessWidget {
  final Story story;
  final String heroTag;

  const StoryDetailPage({
    super.key,
    required this.story,
    required this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final saved = context.select<FeedController, bool>(
      (c) => c.isBookmarked(story.id),
    );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('Read Story'),
            actions: [BookmarkButton(storyId: story.id, isSaved: saved)],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
            sliver: SliverList.list(
              children: [
                Row(
                  children: [
                    Hero(
                      tag: heroTag,
                      child: StoryBadge(id: story.id, size: 60),
                    ),
                    const SizedBox(width: 14),
                    Wrap(
                      spacing: 8,
                      children: [
                        Chip(
                          avatar: const Icon(Icons.person, size: 16),
                          label: Text('Author ${story.authorId}'),
                        ),
                        Chip(
                          avatar: const Icon(Icons.schedule, size: 16),
                          label: Text(story.readingTime),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  story.headline,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Divider(color: scheme.outlineVariant),
                const SizedBox(height: 16),
                Text(
                  story.content,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(height: 1.7),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
