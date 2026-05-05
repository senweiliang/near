import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat.dart';
import 'log.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  final Chat chat;
  const SettingsPage({super.key, required this.chat});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _nameCtrl;
  bool _saving = false;
  bool _hasUnsaved = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.chat.myName);
    _nameCtrl.addListener(_onNameTyping);
    widget.chat.addListener(_onChatChanged);
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChatChanged);
    _nameCtrl.removeListener(_onNameTyping);
    _nameCtrl.dispose();
    super.dispose();
  }

  void _onNameTyping() {
    final dirty = _nameCtrl.text.trim() != widget.chat.myName &&
        _nameCtrl.text.trim().isNotEmpty;
    if (dirty != _hasUnsaved) {
      setState(() => _hasUnsaved = dirty);
    }
  }

  void _onChatChanged() {
    if (!mounted) return;
    setState(() {
      if (!_hasUnsaved && _nameCtrl.text != widget.chat.myName) {
        _nameCtrl.text = widget.chat.myName;
      }
    });
  }

  Future<void> _saveName() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || name == widget.chat.myName) {
      FocusScope.of(context).unfocus();
      return;
    }
    setState(() => _saving = true);
    await widget.chat.updateMyName(name);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _hasUnsaved = false;
    });
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Name saved',
          style: AppFonts.body(size: 13, color: Colors.white),
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        backgroundColor: AppColors.bgApp,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Settings',
          style: AppFonts.body(
            size: 17,
            weight: FontWeight.w700,
            color: AppColors.ink,
          ),
        ),
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.chevron_left_rounded,
              color: AppColors.ink2, size: 28),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _Section(title: 'Profile', children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Display name',
                    style: AppFonts.mono(
                      size: 11,
                      color: AppColors.ink3,
                      letterSpacing: 0.18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameCtrl,
                    style: AppFonts.body(
                      size: 16,
                      weight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: AppColors.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                            color: AppColors.accent, width: 1.5),
                      ),
                      suffixIconConstraints:
                          const BoxConstraints(minWidth: 0, minHeight: 36),
                      suffixIcon: _hasUnsaved
                          ? Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: TextButton(
                                onPressed: _saving ? null : _saveName,
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(48, 32),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10),
                                  visualDensity: VisualDensity.compact,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: _saving
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppColors.accent,
                                        ),
                                      )
                                    : Text(
                                        'Save',
                                        style: AppFonts.body(
                                          size: 14,
                                          weight: FontWeight.w600,
                                          color: AppColors.accentDeep,
                                        ),
                                      ),
                              ),
                            )
                          : null,
                    ),
                    onSubmitted: (_) => _saveName(),
                  ),
                ],
              ),
            ),
            const _RowDivider(),
            _ReadonlyRow(
              label: 'Handle',
              value: '@${_short(widget.chat.myId)}',
              onLongPress: () async {
                await Clipboard.setData(
                    ClipboardData(text: widget.chat.myId));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Full ID copied',
                        style: AppFonts.body(size: 13, color: Colors.white),
                      ),
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                }
              },
            ),
          ]),
          const SizedBox(height: 18),
          _Section(title: 'Receiving', children: [
            _ToggleRow(
              label: 'Auto-accept files',
              sub: widget.chat.autoAcceptFiles
                  ? 'Files arrive without confirmation'
                  : 'Sender waits for you to accept each file',
              value: widget.chat.autoAcceptFiles,
              onChanged: (v) => widget.chat.setAutoAcceptFiles(v),
            ),
            if (Platform.isAndroid) ...[
              const _RowDivider(),
              _ToggleRow(
                label: 'Stay connected in background',
                sub: widget.chat.stayConnectedInBackground
                    ? 'Notification keeps Near reachable when screen is off'
                    : 'Android may drop the connection within seconds of locking',
                value: widget.chat.stayConnectedInBackground,
                onChanged: (v) =>
                    widget.chat.setStayConnectedInBackground(v),
              ),
            ],
          ]),
          const SizedBox(height: 18),
          _Section(title: 'Diagnostics', children: [
            _NavRow(
              icon: Icons.terminal_rounded,
              label: 'Logs',
              onTap: () {
                showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: AppColors.bgApp,
                  shape: const RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(18)),
                  ),
                  builder: (_) => const _SettingsLogsSheet(),
                );
              },
            ),
          ]),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Near · v0.1.0',
              style: AppFonts.mono(
                size: 11,
                color: AppColors.ink3,
                letterSpacing: 0.18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _short(String id) =>
      id.length <= 4 ? id : id.substring(0, 4);
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
          child: Text(
            title.toUpperCase(),
            style: AppFonts.mono(
              size: 11,
              color: AppColors.ink3,
              letterSpacing: 0.36,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 14),
      child: Divider(height: 1, color: AppColors.line),
    );
  }
}

class _ReadonlyRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onLongPress;
  const _ReadonlyRow(
      {required this.label, required this.value, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppFonts.body(
                  size: 15,
                  weight: FontWeight.w500,
                  color: AppColors.ink,
                ),
              ),
            ),
            Text(
              value,
              style: AppFonts.mono(
                size: 13,
                color: AppColors.ink3,
                letterSpacing: 0.06,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final String? sub;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppFonts.body(
                      size: 15,
                      weight: FontWeight.w500,
                      color: AppColors.ink,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub!,
                      style: AppFonts.mono(
                        size: 11,
                        color: AppColors.ink3,
                        letterSpacing: 0.06,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch.adaptive(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.accent,
            ),
          ],
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _NavRow(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.ink2),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: AppFonts.body(
                  size: 15,
                  weight: FontWeight.w500,
                  color: AppColors.ink,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                size: 22, color: AppColors.ink3),
          ],
        ),
      ),
    );
  }
}

class _SettingsLogsSheet extends StatelessWidget {
  const _SettingsLogsSheet();

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Text(
                    'Logs',
                    style: AppFonts.body(
                      size: 16,
                      weight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: AppLog.dump()));
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Logs copied',
                              style: AppFonts.body(
                                  size: 13, color: Colors.white),
                            ),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: Text(
                      'Copy',
                      style: AppFonts.body(
                          size: 13,
                          weight: FontWeight.w600,
                          color: AppColors.accentDeep),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accentDeep,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  IconButton(
                    onPressed: () => AppLog.clear(),
                    icon: const Icon(Icons.delete_outline_rounded,
                        size: 18, color: AppColors.ink3),
                    tooltip: 'Clear',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    icon: const Icon(Icons.close_rounded,
                        size: 20, color: AppColors.ink3),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.line),
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: AppLog.revision,
                builder: (_, _, _) {
                  final entries = AppLog.snapshot();
                  if (entries.isEmpty) {
                    return Center(
                      child: Text(
                        'No logs yet',
                        style: AppFonts.mono(
                            size: 12, color: AppColors.ink3),
                      ),
                    );
                  }
                  return SelectionArea(
                    child: ListView.builder(
                      controller: scrollController,
                      padding:
                          const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: entries.length,
                      itemBuilder: (_, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          entries[i],
                          style: AppFonts.mono(
                            size: 11,
                            color: AppColors.ink2,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
