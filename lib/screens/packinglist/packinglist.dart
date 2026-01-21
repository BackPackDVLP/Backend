import 'package:backend/models/packinglist_model.dart';
import 'package:backend/widget/agencyLogo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../blocs/groupinformation/groupinformation_bloc.dart';
import 'package:backend/widget/coupon.dart' as CouponWidget;

class PackingListScreen extends StatefulWidget {
  final ScrollController scrollController;
  const PackingListScreen({super.key, required this.scrollController});

  static const String routeName = '/packinglist';

  static Route route() {
    return MaterialPageRoute(
      builder: (_) => PackingListScreen(scrollController: ScrollController()),
      settings: const RouteSettings(name: routeName),
    );
  }

  @override
  State<PackingListScreen> createState() => _PackingListScreenState();
}

class _PackingListScreenState extends State<PackingListScreen> {
  Map<String, Map<String, bool>> checkedItems = {};
  bool _isLoading = true; // Flag to indicate loading state

  @override
  void initState() {
    super.initState();
    setState(() {
      _isLoading = false; // Data loaded, set loading to false
    });
  }

  // Load checked items from SharedPreferences
  Future<void> _loadCheckedItemsFromPrefs(
      List<PackinglistCategories> categories) async {
    final prefs = await SharedPreferences.getInstance();
    for (var category in categories) {
      checkedItems[category.categoryName] = {};
      for (var item in category.items) {
        checkedItems[category.categoryName]![item] =
            prefs.getBool('${category.categoryName}-$item') ?? false;
      }
    }
  }



  // Helper function to convert string to icon
  IconData stringToIcon(String name) {
    switch (name.toLowerCase()) {
      case 'clothes':
        return MdiIcons.tshirtCrew;
      case 'documents':
        return MdiIcons.fileDocument;
      case 'electronics':
        return MdiIcons.laptop;
      case 'toiletries':
        return MdiIcons.toothbrush;
      default:
        return MdiIcons.alertCircleOutline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.fromARGB(5, 23, 62, 27),
            Color.fromARGB(255, 239, 224, 213),
          ],
          stops: [-0.5, 1.0],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        body: BlocBuilder<GroupInformationBloc, GroupInformationState>(
          builder: (context, state) {
            if (state is GroupInformationLoaded) {
              final packingListCategories =
                  state.groupInformation.packinglistCategories;
              final coupon = state.groupInformation.coupons;

              if (checkedItems.isEmpty) {
                _loadCheckedItemsFromPrefs(packingListCategories).then((_) {
                  setState(() {});
                });
              }

              for (var category in packingListCategories) {
                checkedItems[category.categoryName] ??= {};
                for (var item in category.items) {
                  checkedItems[category.categoryName]![item] ??= false;
                }
              }

              return _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.black))
                  : CustomScrollView(
                      controller: widget.scrollController,
                      slivers: [
                        SliverAppBar(
                          backgroundColor: Colors.transparent,
                          elevation: 0,
                          pinned: false,
                          floating: true,
                          title: Center(
                            child: BlocBuilder<GroupInformationBloc,
                                GroupInformationState>(
                              builder: (context, state) {
                                if (state is GroupInformationLoaded) {
                                  final agencyCode =
                                      state.groupInformation.agencyCode;
                                  return SizedBox(
                                    width: MediaQuery.of(context).size.width *
                                        0.4,
                                    height: MediaQuery.of(context).size.height *
                                        0.08,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child:
                                          AgencyLogo(agencyCode: agencyCode),
                                    ),
                                  );
                                } else {
                                  return const SizedBox(height: 40);
                                }
                              },
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Center(
                                  child: Text(
                                    'Din huskeliste:',
                                    style: GoogleFonts.kanit(
                                        fontSize: 21,
                                        fontWeight: FontWeight.w300,
                                        color: Colors.white),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                // Vaccine Card
                                SizedBox(
                                  height: 110,
                                  child: Card(
                                    shadowColor: Colors.black,
                                    elevation: 0,
                                    color: const Color.fromARGB(127, 239, 224, 213),
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    child: ListTile(
                                      subtitle: Column(
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 4.0),
                                            child: Text('Vaccineanbefalinger',
                                                style: TextStyle(
                                                    color: Colors.black,
                                                    fontSize: 16,
                                                    fontFamily:
                                                        GoogleFonts.kanit()
                                                            .fontFamily,
                                                    fontWeight:
                                                        FontWeight.w200)),
                                          ),
                                          Image.asset('assets/images/DLVS.png'),
                                        ],
                                      ),
                                      onTap: () async {
                                        final url = Uri.parse(
                                            'https://www.sikkerrejse.dk/rejsevacciner/?_gl=1*jnav1i*_up*MQ..&gclid=CjwKCAiA6t-6BhA3EiwAltRFGBt9XwuuSKmOrlre3e1gt8ho6fSrJsq1UTroWC9EQOsLk0TxxdRveRoCNWgQAvD_BwE');
                                        if (await canLaunchUrl(url)) {
                                          await launchUrl(url);
                                        } else {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(const SnackBar(
                                                  content: Text(
                                                      'Could not launch URL')));
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                // Pas & Visum Card
                                SizedBox(
                                  height: 110,
                                  child: Card(
                                    shadowColor: Colors.black,
                                    elevation: 0,
                                    color: const Color.fromARGB(127, 239, 224, 213),
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 4),
                                    child: ListTile(
                                      subtitle: Column(
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                bottom: 4.0),
                                            child: Text('Pas- & visumkrav',
                                                style: TextStyle(
                                                    color: Colors.black,
                                                    fontSize: 16,
                                                    fontFamily:
                                                        GoogleFonts.kanit()
                                                            .fontFamily,
                                                    fontWeight:
                                                        FontWeight.w200)),
                                          ),
                                          SizedBox(
                                              height: 50,
                                              child: Image.asset(
                                                  'assets/images/UM.png')),
                                        ],
                                      ),
                                      onTap: () async {
                                        final url = Uri.parse(
                                            'https://um.dk/rejse-og-ophold/rejse-til-udlandet/pas-og-visum');
                                        if (await canLaunchUrl(url)) {
                                          await launchUrl(url);
                                        } else {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(const SnackBar(
                                                  content: Text(
                                                      'Could not launch URL')));
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // Grid of categories
                                MediaQuery.removePadding(
                                  removeBottom: true,
                                  removeTop: true,
                                  context: context,
                                  child: GridView.builder(
                                    physics: const NeverScrollableScrollPhysics(),
                                    shrinkWrap: true,
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 2,
                                      crossAxisSpacing: 10,
                                      mainAxisSpacing: 10,
                                    ),
                                    itemCount: packingListCategories.length,
                                    itemBuilder: (context, categoryIndex) {
                                      final category =
                                          packingListCategories[categoryIndex];
                                      return SizedBox(
                                        child: GestureDetector(
                                          onTap: () {
                                            // ... Dialog code remains unchanged ...
                                          },
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: const Color.fromARGB(
                                                  127, 239, 224, 213),
                                              borderRadius:
                                                  BorderRadius.circular(10.0),
                                              boxShadow: const [
                                                BoxShadow(
                                                  color: Color(0x1A000000),
                                                  spreadRadius: 1,
                                                  blurRadius: 2,
                                                  offset: Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    stringToIcon(category.iconName),
                                                    size: 40,
                                                  ),
                                                  const SizedBox(height: 10),
                                                  Text(category.categoryName,
                                                      textAlign: TextAlign.center,
                                                      style: GoogleFonts.kanit(
                                                          color: Colors.black,
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.w500)),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // Coupons list
                                MediaQuery.removePadding(
                                  removeTop: true,
                                  context: context,
                                  child: ListView.builder(
                                    physics: const NeverScrollableScrollPhysics(),
                                    shrinkWrap: true,
                                    itemCount: coupon?.length ?? 0,
                                    itemBuilder: (context, index) {
                                      final couponItem = coupon?[index];
                                      if (couponItem != null) {
                                        return CouponWidget.Coupon(coupon: couponItem);
                                      } else {
                                        return const SizedBox.shrink();
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(height: 55),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
            } else if (state is GroupInformationError) {
             

              return Center(child: Text('Error: ${state.message}'));
            } else {
              return const Center(
                  child: CircularProgressIndicator(
                color: Colors.black,
              )); // Or a placeholder widget while data is loading
            }
          },
        ),
      ),
    );
  }
}
